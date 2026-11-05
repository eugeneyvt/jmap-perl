use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='d'x64}
use JMAP::ImapDB;
use JMAP::API;
use JMAP::Replica;
use JMAP::ReplicaWorker;
{
  package MirrorFixtureDB;
  use parent 'JMAP::ImapDB';
  sub backend_cmd {
    my ($self,$cmd,$folder,$validity,$uid,$bytes,$f)=@_;
    die 'provider forbidden' if $self->{forbidden};
    die 'wrong method' unless $cmd eq 'imap_stream_raw';
    die 'network inside transaction' if $self->in_transaction;
    $self->{fetches}++;
    print {$f} $self->{raw} or die $!;
    return {bytes=>length($self->{raw})};
  }
}
my $dir=abs_path(tempdir(CLEANUP=>1));mkdir "$dir/box";mkdir "$dir/spool";
my $db=MirrorFixtureDB->new('mirror');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
$db->{raw}="From: Synthetic <sender\@example.invalid>\r\nSubject: test\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nA searchable fixture body.\r\n";
$db->begin;
$db->dinsert('ifolders',{ifolderid=>1,jmailboxid=>'inbox',sep=>'/',imapname=>'INBOX',label=>'INBOX',uidvalidity=>8,uidfirst=>1,uidnext=>2});
$db->dinsert('imessages',{ifolderid=>1,uid=>1,msgid=>'stable'});
$db->dmake('jmessages',{msgid=>'stable',thrid=>'thread',keywords=>'{}'});
$db->commit;
mkdir "$ENV{JMAP_DATADIR}/mirror";
my $r=JMAP::Replica->new(path=>"$ENV{JMAP_DATADIR}/mirror/replica.sqlite3");
$db->begin;$db->dbh->do('UPDATE imessages SET size=?',{},length($db->{raw}));$db->commit;
my $catalog=$r->reconcile_catalog($db,1);
is($catalog->{queued},1,'bounded metadata reconciliation enqueues a missing source');
is($catalog->{missing},0,'exact source coverage includes queued work');
is($r->reconcile_catalog($db,1)->{queued},0,'existing source is not re-enqueued');
my $box_available=1;
my $store=JMAP::RawStore->new(root=>"$dir/box",account=>'mirror',guard=>sub {$box_available});
my $worker=JMAP::ReplicaWorker->new(db=>$db,replica=>$r,store=>$store,spool=>"$dir/spool");
my $job=$r->claim;
ok($worker->process($job)->{ok},'full worker pipeline commits verified raw, parsed body and index');
is($db->{fetches},1,'one streaming provider fetch');
$db->{forbidden}=1;$box_available=0;
my $api=JMAP::API->new($db);
my $get=$api->api_Email_get({accountId=>'mirror',ids=>['stable'],properties=>[qw(id preview textBody bodyValues)],fetchAllBodyValues=>JSON::XS::true});
is($get->[1]{list}[0]{bodyValues}{1}{value},"A searchable fixture body.\n",'reader obtains original text from SSD without Box or provider');
like($get->[1]{list}[0]{preview},qr/searchable fixture/,'preview already available');
my $parsed=$r->parsed_message('stable');
my $reference=Data::JSEmail::parse($db->{raw},'stable');
for my $property (qw(subject from sender to cc bcc replyTo messageId references inReplyTo textBody htmlBody attachments bodyValues)) {
  is_deeply($parsed->{$property},$reference->{$property},"streamed MIME preserves native $property contract");
}
opendir my $d,"$dir/spool";my @left=grep {!/^\./} readdir($d);closedir $d;
is(scalar @left,0,'per-job scratch removed');
$db->begin;$db->dbh->do('DELETE FROM imessages WHERE ifolderid=1 AND uid=1');$db->commit;
is($r->reconcile_catalog($db,1)->{obsolete},1,'removed source becomes an explicit tombstone');
is($r->{dbh}->selectrow_array("SELECT state FROM replica_jobs"),'obsolete','tombstoned source is not retried');
ok($r->parsed_message('stable'),'tombstone preserves original document evidence');
$db->begin;$db->dinsert('imessages',{ifolderid=>1,uid=>1,msgid=>'stable',size=>length($db->{raw})});$db->commit;
is($r->reconcile_catalog($db,1)->{queued},1,'reappearing unchanged source becomes runnable');
is($r->{dbh}->selectrow_array("SELECT state FROM replica_jobs"),'pending','reappearance has explicit pending status');
$box_available=1;
ok($worker->process($r->claim)->{ok},'saved original supports reappearing UID without provider');
$box_available=0;$db->{is_gmail}=1;
$db->begin;
$db->dinsert('ifolders',{ifolderid=>2,jmailboxid=>'label',sep=>'/',imapname=>'Label',label=>'Label',uidvalidity=>9,uidfirst=>1,uidnext=>2});
$db->dinsert('imessages',{ifolderid=>2,uid=>1,msgid=>'stable',size=>length($db->{raw})});$db->commit;
$r->reconcile_catalog($db);
my $generation=$r->state->{generation};
ok($worker->process($r->claim)->{ok},'Gmail label alias completes without provider or unavailable Box');
is($r->state->{generation},$generation,'label alias does not rewrite identical index content');
is($r->{dbh}->selectrow_array("SELECT count(*) FROM replica_jobs WHERE state='complete'"),2,'both UID manifests complete');
opendir $d,"$dir/spool";my @scratch=grep {!/^\.{1,2}$/} readdir($d);closedir $d;
is(scalar @scratch,0,'alias leaves no hidden staging files');
done_testing;
