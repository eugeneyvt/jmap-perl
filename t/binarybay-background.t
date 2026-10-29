use strict;
use warnings;
use Test::More;

open my $fh, '<', 'bin/jmap-proxy.pl' or die $!;
my $source = do { local $/; <$fh> };
my ($timer) = $source =~ /my \$sync_timer = AnyEvent->timer\((.*?)\n\);/s;
ok(defined $timer, 'background scheduler exists');
my ($body) = $timer =~ /cb\s*=>\s*sub \{(.*)\n  \},/s;
ok(defined $body, 'scheduler callback can be exercised independently');

my %waiting;
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
done_testing;
