use strict;
use warnings;
use Test::More;
use IO::Socket::INET;
use JSON::XS qw(decode_json);
BEGIN {
  require File::Temp;
  $ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);
  $ENV{JMAP_SECRET_KEY}='d' x 64;
}
use JMAP::ImapDB;
use JMAP::API;
{
  package SMTPFixtureDB;
  use parent 'JMAP::ImapDB';
  sub sync_folders { } # this fixture exercises SMTP, never a real IMAP server
  sub get_raw_message {
    return ('message/rfc822',"From: from\@example.invalid\r\nTo: to\@example.invalid\r\nSubject: fixture\r\n\r\nsynthetic only\r\n");
  }
}
my $listener=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>0,Listen=>1,ReuseAddr=>1) or die $!;
my $port=$listener->sockport;
my $server=fork();die $! unless defined $server;
if (!$server) {
  alarm 8;
  my $c=$listener->accept() or die $!;$c->autoflush(1);
  print $c "220 synthetic SMTP\r\n";
  while (my $line=<$c>) {
    if ($line=~/^(?:EHLO|HELO)/i) {print $c "250-synthetic\r\n250 AUTH PLAIN\r\n"}
    elsif ($line=~/^AUTH /i) {print $c "235 2.7.0 authenticated\r\n"}
    elsif ($line=~/^(?:MAIL|RCPT)/i) {print $c "250 2.1.0 accepted\r\n"}
    elsif ($line=~/^DATA/i) {
      print $c "354 send data\r\n";
      while (my $body=<$c>) {last if $body eq ".\r\n" || $body eq ".\n"}
      # The receiver accepted the data, then its acknowledgement disappeared.
      # Never print the message or credentials into test output.
      close $c;exit 0;
    } else {print $c "250 OK\r\n"}
  }
  exit 2;
}
close $listener;
my $db=SMTPFixtureDB->new('smtp');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'127.0.0.1',imapPort=>1,
  smtpHost=>'127.0.0.1',smtpPort=>$port,smtpSSL=>1});
$db->begin();$db->dmake('jmessages',{msgid=>'m1',thrid=>'t1',keywords=>'{}'});$db->commit();
my $api=JMAP::API->new($db);
my $request={accountId=>'smtp',create=>{c1=>{emailId=>'m1',identityId=>'id1',envelope=>{
  mailFrom=>{email=>'from@example.invalid'},rcptTo=>[{email=>'to@example.invalid'}]}}}};
my ($reply)=$api->api_EmailSubmission_set($request);
waitpid $server,0;
is($?,0,'real local SMTP fixture received DATA before dropping acknowledgement');
is($reply->[0],'EmailSubmission/set','public JMAP method returns a structured result');
is($reply->[1]{notCreated}{c1}{type},'serverFail','lost SMTP acknowledgement is not a successful create');
$db->begin();
my $states=$db->dbh->selectall_arrayref('SELECT state FROM jdelivery');
is_deeply($states,[['unknown']],'uncertain transport outcome is persisted');
$db->commit();
my ($retry)=$api->api_EmailSubmission_set($request);
like($retry->[1]{notCreated}{c1}{description},qr/Previous sending outcome is unknown/,'retry of same unresolved operation is stopped before another SMTP connection');
is($db->send_due(),undef,'background timer has nothing eligible to resend');
done_testing;
