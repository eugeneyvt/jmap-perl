use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use IO::Socket;
use Mail::IMAPTalk;
use JMAP::Sync::Common;

{
  package ReconnectFactory;
  our @next;
  our $created = 0;
  our @options;
  sub new { shift; ++$created; @options = @_; return shift @next }
  package ReconnectTransport;
  use parent 'JMAP::Sync::Common';
  sub _imap_class { 'ReconnectFactory' }
}

my @peers;
sub connection {
  my ($state) = @_;
  my ($client, $peer) = IO::Socket->socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC);
  die 'socketpair failed' unless $client && $peer;
  push @peers, $peer;
  return (Mail::IMAPTalk->new(Socket => $client,
    State => $state // Mail::IMAPTalk::Authenticated(), UseBlocking => 0), $peer);
}
sub backend {
  my ($imap) = @_;
  return bless { imap => $imap, auth => { imapHost => 'example.invalid', imapPort => 993,
    username => 'test@example.invalid', password => 'synthetic-only' } }, 'ReconnectTransport';
}
sub discard {
  my ($b) = @_;
  if (my $imap = delete $b->{imap}) {
    my $s = $imap->release_socket(); $s->close() if $s;
  }
}

my ($healthy, $healthy_peer) = connection();
my $b = backend($healthy);
is($b->connect_imap(), $healthy, 'reuse an authenticated live connection');
is($ReconnectFactory::created, 0, 'healthy reuse does not reconnect');
ok(!IO::Select->new($healthy_peer)->can_read(0), 'health check sends no IMAP command');
discard($b);

for my $notice ('', "* BYE idle timeout\r\n") {
  my ($stale, $peer) = connection();
  $peer->syswrite($notice) if length $notice;
  $peer->close();
  my ($fresh) = connection();
  @ReconnectFactory::next = ($fresh);
  $b = backend($stale);
  my $before = $ReconnectFactory::created;
  is($b->connect_imap(), $fresh, 'closed idle socket is replaced, with or without BYE');
  is($ReconnectFactory::created, $before + 1, 'one replacement connection is sufficient');
  is($stale->state(), Mail::IMAPTalk::Unconnected(), 'discarded connection cannot be reused');
  my %options = @ReconnectFactory::options;
  is($options{UseSSL}, 1, 'reconnect retains TLS');
  is($options{Password}, 'synthetic-only', 'reconnect retains existing authentication');
  discard($b);
}

{
  my ($unauthenticated) = connection(Mail::IMAPTalk::Connected());
  my ($fresh) = connection(); @ReconnectFactory::next = ($fresh);
  $b = backend($unauthenticated);
  is($b->connect_imap(), $fresh, 'open but unauthenticated socket is replaced');
  discard($b);
}
{
  my ($old) = connection(); my ($fresh) = connection();
  @ReconnectFactory::next = ($fresh); $b = backend($old);
  is($b->connect_imap(1), $fresh, 'explicit reconnect replaces a healthy socket too');
  is($old->state(), Mail::IMAPTalk::Unconnected(), 'forced replacement releases old handle');
  discard($b);
}
{
  package BrokenProbe;
  use parent -norequire, 'Mail::IMAPTalk';
  sub is_open { die 'broken connection probe' }
  package main;
  my ($old) = connection(); bless $old, 'BrokenProbe';
  my ($fresh) = connection(); @ReconnectFactory::next = ($fresh); $b = backend($old);
  is($b->connect_imap(), $fresh, 'failed liveness probe also reconnects');
  discard($b);
}
{
  my ($old, $peer) = connection(); $peer->close(); @ReconnectFactory::next = ();
  $b = backend($old); my $before = $ReconnectFactory::created;
  eval { $b->connect_imap() };
  like($@, qr/Could not connect to IMAP server/, 'unavailable provider is a failure, not an empty mailbox');
  is($ReconnectFactory::created - $before, 3, 'connection attempts remain bounded');
  ok(!$b->{imap}, 'no unusable connection remains cached');
  discard($b);
}
$_->close() for grep { defined fileno($_) } @peers;
done_testing();
