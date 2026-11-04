use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::XS qw(decode_json encode_json);
use JMAP::AtomicFile;

my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/cache.json";
sub read_value {
  open my $f, '<:raw', $path or die $!;
  local $/; return <$f>;
}
my $old = encode_json({value => 'old'});
JMAP::AtomicFile->replace($path, $old);
is(read_value(), $old, 'first durable value written');
is((stat $path)[2] & 0777, 0600, 'new mail files are private');
{
  no warnings 'redefine';
  local *JMAP::AtomicFile::_sync = sub { die "simulated full disk\n" };
  eval { JMAP::AtomicFile->replace($path, '{"incomplete":') };
  like($@, qr/simulated full disk/, 'failed durable write is reported');
}
is(read_value(), $old, 'failed write preserves previous valid content');
is_deeply([glob "$dir/.jmap-write-*"], [], 'owned failed staging file is cleaned up');
my $pid = fork(); die $! unless defined $pid;
if (!$pid) {
  for (1..30) { JMAP::AtomicFile->replace($path, encode_json({value => 'x' x 10000, n => $_})) }
  exit 0;
}
my $invalid = 0;
for (1..300) { eval { decode_json(read_value()) }; $invalid++ if $@ }
waitpid $pid, 0;
is($?, 0, 'writer completes');
is($invalid, 0, 'concurrent reader never sees partial JSON');
is(decode_json(read_value())->{n}, 30, 'last complete replacement readable');
done_testing;
