#!/usr/bin/perl
use strict;use warnings;
use HTTP::Tiny;use JSON::XS;use MIME::Base64 qw(encode_base64);
use IO::Socket::INET;use IO::Select;use Time::HiRes qw(time);
use JMAP::ImapDB;

# Runs only inside the network-isolated smoke container with a tmpfs /data.
my $http=HTTP::Tiny->new(timeout=>3);
for my $aid ('a','b') {
  my $r=$http->post('http://127.0.0.1:8080/api/accounts',{
    headers=>{'Content-Type'=>'application/json'},content=>encode_json({accountid=>$aid,email=>"$aid\@example.invalid",type=>'imap',poolid=>$aid})});
  die "Synthetic account creation failed\n" unless $r->{status}==201;
  my $db=JMAP::ImapDB->new($aid);
  $db->setuser({username=>"$aid\@example.invalid",email=>"$aid\@example.invalid",password=>'synthetic-only',imapHost=>'127.0.0.1',imapPort=>1,imapSSL=>0});
}
my $socket=IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>9000,Proto=>'tcp') or die $!;
$socket->autoflush(1);
my $auth=encode_base64('a@example.invalid:synthetic-only','');
$socket->print("GET /eventsource?types=*&ping=30 HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Basic $auth\r\n\r\n");
my $read_until=sub {
  my ($pattern)=@_;my $buffer='';my $end=time()+3;
  while(time()<$end) {
    next unless IO::Select->new($socket)->can_read(.1);
    last unless $socket->sysread(my $part,8192);
    $buffer.=$part;return $buffer if $buffer=~$pattern;
  }
  die "SSE frame did not arrive within deadline\n";
};
my $initial=$read_until->(qr/event: ping/);
die "Authenticated SSE did not respond immediately\n" unless $initial=~/HTTP\/1\.[01] 200/;
my $mutate=sub {
  my ($login,$target)=@_;
  my $r=$http->post('http://127.0.0.1:9000/jmap',{
    headers=>{'Content-Type'=>'application/json','Authorization'=>'Basic '.encode_base64("$login\@example.invalid:synthetic-only",'')},
    content=>encode_json({using=>['urn:ietf:params:jmap:core','urn:ietf:params:jmap:submission'],methodCalls=>[
      ['Identity/set',{accountId=>$target,update=>{id1=>{textSignature=>'synthetic realtime smoke'}}},'test']]})});
  die "Synthetic JMAP request failed\n" unless $r->{status}==200;
  return decode_json($r->{content});
};
my $own=$mutate->('a','a');
die "Identity update refused\n" unless $own->{methodResponses}[0][0] eq 'Identity/set';
my $state=$read_until->(qr/event: state/);
die "State event has no canonical owner account\n" unless $state=~/"changed"\s*:\s*\{\s*"a"/;
my $foreign=$mutate->('a','b');
die "Foreign account unexpectedly accessible\n" unless $foreign->{methodResponses}[0][0] eq 'error';
$mutate->('b','b');
my $end=time()+.2;
while(time()<$end) {
  next unless IO::Select->new($socket)->can_read(.02);
  last unless $socket->sysread(my $part,8192);
  die "Foreign account state leaked into SSE\n" if $part=~/"b"\s*:/;
}
close $socket;
print "Authenticated SSE startup, state delivery and pool isolation passed.\n";
