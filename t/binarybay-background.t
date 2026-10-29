use strict;
use warnings;
use Test::More;
use JMAP::Realtime;

open my $fh, '<', 'bin/jmap-proxy.pl' or die $!;
my $source = do { local $/; <$fh> };
my ($timer) = $source =~ /my \$sync_timer = AnyEvent->timer\((.*?)\n\);/s;
ok(defined $timer, 'background scheduler exists');
my ($body) = $timer =~ /cb\s*=>\s*sub \{(.*)\n  \},/s;
ok(defined $body, 'scheduler callback can be exercised independently');

my %waiting;
my (%idle_watch, %realtime_sync, %backend, %sync_times);
my $IDLE_FALLBACK = 30;
my @watchers;
sub _ensure_idle { push @watchers, $_[0] }
my @syncs;
sub send_backend_request {
    my ($name, $cmd, $args, $callback) = @_;
    if ($name eq '__accounts__') {
        $callback->([{accountid => 'synthetic', type => 'gmail'},
                     {accountid => 'passthrough', type => 'jmap'}]);
    } else {
        push @syncs, $name;
    }
}
my $callback = eval 'sub {' . $body . '}';
die $@ if $@;
$callback->();
is_deeply(\@syncs, ['synthetic:sync'],
    'registered IMAP account syncs without a browser worker; passthrough is skipped');
$waiting{'synthetic:sync'} = {pending => 1};
$callback->();
is(scalar @syncs, 1, 'slow background sync is not queued repeatedly');
delete $waiting{'synthetic:sync'};
$idle_watch{synthetic}={active=>1,heartbeat=>time()};
$sync_times{synthetic}=time();
$callback->();
is(scalar @syncs,1,'healthy IDLE does not immediately repeat a fresh sync');
$idle_watch{synthetic}{heartbeat}=time()-60;
$callback->();
is(scalar @syncs,2,'expired IDLE heartbeat restores background reconciliation');
$idle_watch{retired}={active=>1};$backend{'retired:idle'}={};
$callback->();
ok(!exists($idle_watch{retired}) && !exists($backend{'retired:idle'}),
   'account removal drops the provider watcher');
ok(!grep($_ eq 'passthrough',@watchers),'JMAP passthrough never opens an IMAP watcher');
done_testing;
