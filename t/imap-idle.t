use strict;
use warnings;
use Test::More;
use IO::Socket::UNIX;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use IO::Select;
use JSON::XS;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
use JMAP::IMAPIdle;
use JMAP::Realtime;

sub start_watch {
  my (%opts) = @_;
  my ($provider, $client) = IO::Socket::UNIX->socketpair(AF_UNIX,SOCK_STREAM,PF_UNSPEC);
  my ($parent, $ipc) = IO::Socket::UNIX->socketpair(AF_UNIX,SOCK_STREAM,PF_UNSPEC);
  $_->autoflush(1) for ($provider,$client,$parent,$ipc);
  my $pid = fork(); die $! unless defined $pid;
  if (!$pid) {
    close $provider; close $parent;
    eval { JMAP::IMAPIdle->watch(socket=>$client,parent=>$ipc,
      renew_seconds=>0.2,heartbeat_seconds=>0.05,command_timeout=>0.5,
      on_status=>sub {$ipc->print("active\n")}, on_change=>sub {$ipc->print("changed\n")}, %opts) };
    $ipc->print("failed\n") if $@;
    close $client; close $ipc; exit 0;
  }
  close $client; close $ipc;
  return ($provider,$parent,$pid);
}
sub line {
  my ($s) = @_;
  my $end=time()+2;my $line='';
  while(time()<$end) {
    next unless IO::Select->new($s)->can_read(.05);
    return undef unless $s->sysread(my $char,1);
    $line.=$char;return $line if $char eq "\n";
  }
  return undef;
}
sub reap {
  my ($pid)=@_;my $end=time()+2;
  while(time()<$end) {return 1 if waitpid($pid,WNOHANG)==$pid;sleep .01}
  kill 'TERM',$pid;waitpid($pid,0);return 0;
}

{
  my ($server,$parent,$pid)=start_watch();
  my $cmd=line($server);like($cmd,qr/^BBIDLE1 IDLE\r\n$/,'starts IDLE on the dedicated socket');
  $server->print("+ idling\r\n");
  is(line($parent),"active\n",'only continuation marks watcher healthy');
  is(line($parent),"changed\n",'connection catches up arrivals missed while disconnected');
  $server->print("* 4 EXISTS\r\n");is(line($parent),"changed\n",'EXISTS emits change without polling');
  $server->print("* 2 EXPUNGE\r\n");is(line($parent),"changed\n",'EXPUNGE emits change');
  $server->print("* 1 FETCH (FLAGS (\\Seen))\r\n");
  # Heartbeats may be interleaved, but the notification must arrive.
  my @events;
  for (1..4) {push @events,line($parent);last if defined($events[-1]) && $events[-1] eq "changed\n"}
  ok(grep(defined($_)&&$_ eq "changed\n",@events),'flag updates emit change');
  is(line($server),"DONE\r\n",'renewal ends IDLE before another command');
  $server->print("BBIDLE1 OK idle completed\r\n");
  like(line($server),qr/^BBIDLE2 IDLE\r\n$/,'re-enters IDLE after tagged completion');
  $server->print("+ idling\r\n");
  close $parent;
  ok(reap($pid),'account removal / parent EOF leaves no orphan watcher');
  close $server;
}
{
  my ($server,$parent,$pid)=start_watch();line($server);
  $server->print("BBIDLE1 NO temporarily unavailable\r\n");
  is(line($parent),"failed\n",'refused IDLE returns to parent fallback');
  ok(reap($pid),'refused watcher exits');close $parent;close $server;
}
{
  my ($server,$parent,$pid)=start_watch(command_timeout=>0.05);line($server);
  is(line($parent),"failed\n",'missing continuation has a bounded deadline');
  ok(reap($pid),'timed-out watcher exits');close $parent;close $server;
}
is_deeply(JMAP::Realtime::state_event('gmail:sync',{Email=>'2'}),
  {'@type'=>'StateChange',changed=>{gmail=>{Email=>'2'}}},
  'background worker suffix never leaks into authenticated account IDs');
my $numeric=JMAP::Realtime::state_event('gmail:sync',{Email=>2});
like(JSON::XS::encode_json($numeric),qr/"Email":"2"/,'wire state counters are JSON strings');
ok(!JMAP::Realtime::needs_poll({active=>1,heartbeat=>100},100,101,300),'healthy IDLE uses events');
ok(JMAP::Realtime::needs_poll({active=>1,heartbeat=>100},100,150,300),'lost watcher heartbeat restores polling');
ok(JMAP::Realtime::needs_poll({active=>0},100,101,300),'disconnect restores polling');
ok(JMAP::Realtime::needs_poll({active=>1,heartbeat=>499},100,500,300),'healthy watcher retains a periodic reconciliation backstop');
my $pending={};
JMAP::Realtime::merge_state($pending,{'changed'=>{a=>{Email=>'1'},b=>{Mailbox=>'2'}}});
JMAP::Realtime::merge_state($pending,{'changed'=>{a=>{Email=>'3',Mailbox=>'4'}}});
is_deeply($pending,{a=>{Email=>'3',Mailbox=>'4'},b=>{Mailbox=>'2'}},
  'slow SSE consumer preserves latest states for every account and type');
done_testing;
