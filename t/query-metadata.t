use strict;
use warnings;
use Test::More;
use JSON::XS qw(encode_json);
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='d'x64}
use JMAP::ImapDB;
use JMAP::API;
my $db=JMAP::ImapDB->new('metadata');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
$db->begin;
for my $n (1..100) {
  $db->dmake('jmessages',{msgid=>"m$n",thrid=>"t$n",internaldate=>$n,keywords=>'{}',msgfrom=>'synthetic@example.invalid',msgsubject=>'Synthetic',msgsize=>123});
  $db->dmake('jmessagemap',{msgid=>"m$n",jmailboxid=>'inbox'});
  $db->dmake('jthreads',{thrid=>"t$n",data=>encode_json(["m$n"])});
}
$db->commit;
my $api=JMAP::API->new($db);
my @ids=map {"m$_"} 1..100;
my @properties=qw(id subject from keywords mailboxIds threadId receivedAt size);
my $sql_count=0;my $dbh=$db->_connection;
$dbh->sqlite_trace(sub {$sql_count++ if $_[0]=~/^SELECT/});
my ($metadata)=$api->api_Email_get({accountId=>'metadata',ids=>\@ids,properties=>\@properties});
is(scalar @{$metadata->[1]{list}},100,'batch metadata returns every requested message');
cmp_ok($sql_count,'<=',4,'100-message metadata/membership fetch uses a constant number of SELECTs');
is_deeply($metadata->[1]{list}[0]{mailboxIds},{inbox=>JSON::XS::true},'batch membership preserves JMAP booleans');
$sql_count=0;
my ($threads)=$api->api_Thread_get({accountId=>'metadata',ids=>[map {"t$_"} 1..100]});
is(scalar @{$threads->[1]{list}},100,'batch thread fetch returns requested conversations');
cmp_ok($sql_count,'<=',4,'thread data and chronological membership are read in batches');
$dbh->sqlite_trace(undef);
my $parsed={preview=>'A persisted preview',hasAttachment=>JSON::XS::true,messageId=>['fixture@example.invalid'],
  inReplyTo=>undef,references=>undef,sender=>undef,replyTo=>undef,
  attachments=>[{partId=>'2',blobId=>'m-m1-2',size=>3,type=>'application/pdf',name=>'fixture.pdf'}]};
$db->write_parsed_msg('m1',$parsed);
my ($first)=$api->api_Email_get({accountId=>'metadata',ids=>['m1'],properties=>[qw(id preview hasAttachment messageId attachments)]});
is($first->[1]{list}[0]{preview},'A persisted preview','first access fills summary from the existing parsed cache');
unlink "$ENV{JMAP_DATADIR}/metadata/parsed/m1.json" or die $!;
{
  no warnings 'redefine';
  local *JMAP::ImapDB::fill_messages=sub {die 'body download must not run for a persisted list summary'};
  my ($second)=$api->api_Email_get({accountId=>'metadata',ids=>['m1'],properties=>[qw(id preview hasAttachment messageId replyTo attachments)]});
  is($second->[1]{list}[0]{preview},'A persisted preview','evicting parsed body does not cause a provider fetch for the list');
  is_deeply($second->[1]{list}[0]{messageId},['fixture@example.invalid'],'immutable list header metadata survives parsed eviction');
  is_deeply($second->[1]{list}[0]{attachments},$first->[1]{list}[0]{attachments},'attachment metadata survives parsed eviction without downloading its bytes');
  eval {$api->api_Email_get({accountId=>'metadata',ids=>['m1'],properties=>[qw(id textBody)]})};
  like($@,qr/body download must not run/,'actual body requests still require parsed/raw content');
}
# A damaged summary is a recoverable miss, never silently replaced with nulls.
$db->begin;$db->dbh->do('UPDATE jemailsummary SET payload=? WHERE msgid=?',{},'{}','m1');$db->commit;
$db->write_parsed_msg('m1',$parsed);
my ($healed)=$api->api_Email_get({accountId=>'metadata',ids=>['m1'],properties=>[qw(preview)]});
is($healed->[1]{list}[0]{preview},'A persisted preview','incomplete summary is rebuilt from parsed data');
$db->begin;$db->dbh->do("UPDATE jemailsummary SET mtime=1 WHERE msgid='m1'");$db->commit;
$db->fill_messages('m1');
$db->begin_read;
is(($db->dbh->selectrow_array("SELECT mtime FROM jemailsummary WHERE msgid='m1'"))[0],1,'repeated parsed-cache hit does not rewrite an unchanged persisted summary');
$db->commit;
my ($unknown)=$api->api_Email_get({accountId=>'metadata',ids=>['missing','m1','m1'],properties=>['id']});
is_deeply($unknown->[1]{notFound},['missing'],'missing IDs remain notFound');
is(scalar @{$unknown->[1]{list}},1,'duplicate requested IDs remain deduplicated');
done_testing;
