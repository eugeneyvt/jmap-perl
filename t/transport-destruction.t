use strict;
use warnings;
use Test::More;
use IO::Socket;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use JMAP::Sync::Common;
{
  package DestructionIMAP;
  sub logout {die 'destructor must not send a blocking LOGOUT'}
  sub release_socket {delete $_[0]{socket}}
}
my ($client,$peer)=IO::Socket->socketpair(AF_UNIX,SOCK_STREAM,PF_UNSPEC);
my $backend=bless {imap=>bless({socket=>$client},'DestructionIMAP')},'JMAP::Sync::Common';
eval {$backend->DESTROY()};
is($@,'','retiring transport closes locally without protocol IO');
ok(!defined(fileno($client)),'owned connection is closed');
is($peer->sysread(my $data,1),0,'provider sees connection closure');
eval {$backend->DESTROY()};is($@,'','cleanup is safe to repeat');
$peer->close();
done_testing;
