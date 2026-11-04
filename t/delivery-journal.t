use strict;
use warnings;
use Test::More;
BEGIN {
  require File::Temp;
  $ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);
  $ENV{JMAP_SECRET_KEY}='b' x 64;
}
use JMAP::ImapDB;
use JMAP::Delivery;
{
  package SyntheticDeliveryDB;
  use parent 'JMAP::ImapDB';
  sub backend_cmd {
    my ($self,$cmd) = @_;
    die "unexpected external operation" unless $cmd eq 'send_email';
    $self->{sent}++;
    die "acknowledgement lost after acceptance\n" if $self->{lose_ack};
    return 1;
  }
}
my $db = SyntheticDeliveryDB->new('delivery');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
my $envelope = {mailFrom=>{email=>'from@example.invalid'},rcptTo=>[{email=>'to@example.invalid'}]};
my $seq=0;
sub prepare {
  my (%extra)=@_;
  my $id='m'.++$seq;
  $db->begin(); $db->dmake('jmessages',{msgid=>$id,thrid=>$id,keywords=>'{}'}); $db->commit();
  return JMAP::Delivery->prepare($db,msgid=>$id,thrid=>$id,envelope=>$envelope,
    message=>"From: from\@example.invalid\r\n\r\nsynthetic\r\n",held=>1,sendat=>time()-1,%extra);
}
sub state {
  my ($id)=@_;$db->begin();
  my $s=$db->dbh->selectrow_hashref('SELECT * FROM jdelivery WHERE jsubid=?',{},$id);
  $db->commit();return $s->{state};
}
my $p=prepare();
is(state($p->{jsubid}),'prepared','job is durable before SMTP');
ok(-f "$ENV{JMAP_DATADIR}/delivery/outbox/$p->{jsubid}.eml",'prepared job has a complete payload');
is(JMAP::Delivery->send($db,$p->{jsubid}),'confirmed','successful SMTP recorded');
is(JMAP::Delivery->send($db,$p->{jsubid}),'confirmed','confirmed job is not resent');
is($db->{sent},1,'only one transport call');
$p=prepare();$db->{lose_ack}=1;
is(JMAP::Delivery->send($db,$p->{jsubid}),'unknown','lost acknowledgement is an unknown outcome');
my $before=$db->{sent};
$db->send_due();$db->send_due();
is($db->{sent},$before,'periodic sender never repeats uncertain SMTP delivery');
is($db->next_send_due(),undef,'unknown job does not schedule an endless retry');
$db->{lose_ack}=0;
$p=prepare();
$db->write_subdir('outbox',"$p->{jsubid}.eml",'corrupt');
is(JMAP::Delivery->send($db,$p->{jsubid}),'unknown','corrupt payload is not sent or marked delivered');
is($db->{sent},$before,'corrupt payload never reaches SMTP');
$p=prepare();
my ($updated,$errors)=$db->update_submissions({$p->{jsubid}=>{undoStatus=>'canceled'}},sub {$_[0]});
ok(exists $updated->{$p->{jsubid}},'prepared held message can be canceled');
$db->send_due();
is($db->{sent},$before,'canceled held message is not sent');
$p=prepare();
my $pid=fork();die $! unless defined $pid;
if (!$pid) {
  $db->begin();
  $db->dbh->do("UPDATE jdelivery SET state='sending',owner_pid=? WHERE jsubid=?",{},$$,$p->{jsubid});
  $db->commit();
  exit 0; # simulates loss of the worker after persisting attempt intent
}
waitpid $pid,0;
is(JMAP::Delivery->recover($db),1,'dead sending owner is reconciled to unknown');
is(state($p->{jsubid}),'unknown','recovery cannot claim the external send did not happen');
$db->send_due();
is($db->{sent},$before,'restart recovery does not blindly resend');
$p=prepare();
$db->begin();$db->dbh->do("UPDATE jdelivery SET state='sending',owner_pid=? WHERE jsubid=?",{},$$,$p->{jsubid});$db->commit();
is(JMAP::Delivery->recover($db),0,'another live worker is not recovered underneath its send');
my (undef,$cancel_errors)=$db->update_submissions({$p->{jsubid}=>{undoStatus=>'canceled'}},sub {$_[0]});
is($cancel_errors->{$p->{jsubid}}{type},'cannotUnsend','in-flight or uncertain delivery cannot be canceled as if still held');
done_testing;
