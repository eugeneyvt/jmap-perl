use strict;
use warnings;
use utf8;
use Test::More;
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='a'x64}
use JMAP::ImapDB;
use JMAP::API;
use JMAP::Replica;
{
  package LocalSearchDB;
  use parent 'JMAP::ImapDB';
  sub backend_cmd {die "Provider must not be contacted\n"}
}
my $db=LocalSearchDB->new('local');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
$db->begin;
$db->dinsert('ifolders',{ifolderid=>1,jmailboxid=>'inbox',sep=>'/',imapname=>'INBOX',label=>'INBOX',uidvalidity=>1,uidfirst=>1,uidnext=>5});
for my $n (1..4) {
  $db->dmake('jmessages',{msgid=>"m$n",thrid=>"t$n",internaldate=>$n,keywords=>'{}'});
  $db->dmake('jmessagemap',{msgid=>"m$n",jmailboxid=>$n==4?'archive':'inbox'});
}
$db->commit;
mkdir "$ENV{JMAP_DATADIR}/local";
my $r=JMAP::Replica->new(path=>"$ENV{JMAP_DATADIR}/local/replica.sqlite3");
for my $n (1..4) {
  $r->enqueue({msgid=>"m$n",folder=>1,uidvalidity=>1,uid=>$n,bytes=>1});
  my $job=$r->claim;$r->raw_saved($job,{sha256=>'a'x64,bytes=>1});
  $r->complete($job,{subject=>$n==2?'Счёт за заказ':'Доставка',sender=>'sender@example.invalid',
    body=>$n==2 || $n==4 ? 'Оплата заказа номер 123' : 'Другая тема',attachments=>'invoice.pdf',
    parsed=>{id=>"m$n",bodyStructure=>{type=>'text/plain'},bodyValues=>{},attachments=>[]}});
}
$db->begin_read;my $token=JMAP::Replica->catalog_token($db);$db->commit;
$r->seal_catalog($token,1);$r->set_mode('local',$token);
my $api=JMAP::API->new($db);
sub query {my ($filter,@extra)=@_;$api->api_Email_query({accountId=>'local',filter=>$filter,
  sort=>[{property=>'receivedAt',isAscending=>JSON::XS::false}],limit=>10,@extra})}
is_deeply(query({text=>'Оплата заказа'})->[1]{ids},[qw(m4 m2)],'Cyrillic full text works without a provider');
is_deeply(query({text=>'Оплата заказа',inMailbox=>'inbox'})->[1]{ids},['m2'],'mailbox and full text filters combine');
is_deeply(query({subject=>'Счёт'})->[1]{ids},['m2'],'field-specific subject index');
is_deeply(query({from=>'sender@example.invalid'})->[1]{ids},[qw(m4 m3 m2 m1)],'addresses indexed');
is_deeply(query({text=>'invoice.pdf'})->[1]{ids},[qw(m4 m3 m2 m1)],'attachment names indexed');
is_deeply(query({operator=>'NOT',conditions=>[{text=>'Оплата заказа'}]})->[1]{ids},[qw(m3 m1)],'NOT uses the entire catalog');
is_deeply(query({text=>'OR body *'})->[1]{ids},[],'FTS operators are treated as literal user text');
is_deeply(query({text=>'заказа Оплата'})->[1]{ids},[qw(m4 m2)],'unquoted words match in either order');
is_deeply(query({text=>'"заказа Оплата"'})->[1]{ids},[],'explicit phrase retains word order');
eval {query({text=>'from:sender@example.invalid'})};like($@,qr/Provider-specific search syntax/,'Gmail dialect is not silently misinterpreted');
eval {query({text=>'"unclosed'})};like($@,qr/Unclosed local search phrase/,'unbalanced phrase is explicit error');
my $first=query({text=>'Оплата заказа'});
my $next=query({text=>'Оплата заказа'},position=>1,limit=>1);
is_deeply($next->[1]{ids},['m2'],'subsequent page reads the SQL snapshot');
is($first->[1]{queryState},$next->[1]{queryState},'stable snapshot state across pages');
# The mounted Box is deliberately absent throughout this test; local search
# reads only SSD metadata/text. Index changes invalidate otherwise cached hits.
$r->{dbh}->do("UPDATE replica_fts SET body='Новый текст' WHERE msgid='m2'");
$r->{dbh}->do('UPDATE replica_state SET generation=generation+1');
is_deeply(query({text=>'Оплата заказа'})->[1]{ids},['m4'],'index generation invalidates cached hits');
$db->begin;$db->ddirty('jmessages',{keywords=>'{}'},{msgid=>'m1'});$db->commit;
is_deeply(query({text=>'Оплата заказа'})->[1]{ids},['m4'],'read/star changes do not invalidate indexed content coverage');
$db->begin;$db->dmake('jmessages',{msgid=>'new-unindexed',thrid=>'new',keywords=>'{}'});$db->commit;
eval {query({text=>'unseen-term'})};
like($@,qr/coverage incomplete/,'incomplete local coverage is an explicit unavailable error');
$r->set_mode('provider','ignored');
eval {query({text=>'provider-mode'})};
like($@,qr/Provider must not/,'provider mode remains explicit');
done_testing;
