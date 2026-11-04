package JMAP::AtomicFile;
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use Fcntl qw(O_RDONLY);
use IO::Handle;
use Errno qw(EINTR);

sub ensure_directory {
  my ($class, $path) = @_;
  return if -d $path;
  unless (mkdir($path, 0700)) { die "Cache directory creation failed\n" unless -d $path }
  _sync_directory(dirname($path));
}

# A failed write must never truncate the previous complete value. Keep the
# temporary file on the same filesystem, and make both data and rename durable.
sub replace {
  my ($class, $path, $bytes) = @_;
  die "Undefined file content\n" unless defined $bytes;
  my ($fh, $temp) = tempfile('.jmap-write-XXXXXXXX', DIR => dirname($path), UNLINK => 0);
  my $ok = eval {
    binmode $fh;
    my $offset = 0;
    while ($offset < length $bytes) {
      my $n = syswrite($fh, $bytes, length($bytes) - $offset, $offset);
      next if !defined($n) && $! == EINTR;
      die "Cache write failed\n" unless defined($n) && $n > 0;
      $offset += $n;
    }
    _sync($fh);
    close($fh) or die "Cache close failed\n";
    rename($temp, $path) or die "Cache rename failed\n";
    _sync_directory(dirname($path));
    1;
  };
  my $error = $@;
  unless ($ok) {
    close($fh) if defined fileno($fh);
    unlink $temp; # only our own incomplete staging file
    die $error;
  }
  return 1;
}

sub _sync { $_[0]->sync or die "Cache fsync failed\n" }
sub _sync_directory {
  sysopen(my $dir, $_[0], O_RDONLY) or die "Cache directory open failed\n";
  my $ok = $dir->sync;
  close $dir;
  die "Cache directory fsync failed\n" unless $ok;
}
1;
