package JMAP::IMAPIdle;
use strict;
use warnings;
use IO::Select;
use Time::HiRes qw(time);

# Owns an already authenticated, read-only selected connection. The normal
# JMAP/sync connections are never used here. No mailbox mutation is performed.
sub watch {
  my ($class, %args) = @_;
  local $SIG{PIPE} = 'IGNORE';
  my ($socket, $parent) = @args{qw(socket parent)};
  my $on_status = $args{on_status} || sub {};
  my $on_change = $args{on_change} || sub {};
  my $renew = $args{renew_seconds} // 1500;
  my $heartbeat = $args{heartbeat_seconds} // 15;
  my $command_timeout = $args{command_timeout} // 20;
  my $select = IO::Select->new($socket, $parent);
  my ($buffer, $tag, $state, $deadline, $refresh, $next_heartbeat) = ('');
  my $sequence = 0;
  my $write = sub {
    my $text = shift;
    while (length $text) {
      my $n = $socket->syswrite($text);
      die "IDLE write failed\n" unless defined $n && $n > 0;
      substr($text, 0, $n, '');
    }
  };
  my $start = sub {
    $tag = 'BBIDLE' . ++$sequence;
    $write->("$tag IDLE\r\n");
    $state = 'continuation'; $deadline = time() + $command_timeout;
  };
  $start->();
  while (1) {
    my $now = time();
    die "IDLE command timed out\n" if $state ne 'idle' && $now >= $deadline;
    if ($state eq 'idle' && $now >= $refresh) {
      $write->("DONE\r\n"); $state = 'completion'; $deadline = $now + $command_timeout;
    }
    if ($state eq 'idle' && $now >= $next_heartbeat) {
      $on_status->(1); $next_heartbeat = $now + $heartbeat;
    }
    # SSL may already have decrypted data without underlying fd readability.
    my $until = $state eq 'idle'
      ? ($refresh < $next_heartbeat ? $refresh : $next_heartbeat) : $deadline;
    my $timeout = $until - time();
    $timeout = 0 if $timeout < 0; $timeout = 0.25 if $timeout > 0.25;
    my @ready = $socket->can('pending') && $socket->pending()
      ? ($socket) : $select->can_read($timeout);
    for my $fh (@ready) {
      if (fileno($fh) == fileno($parent)) {
        # Parent closes the socket when the account is removed or on shutdown.
        # Never leave an orphan watcher holding a provider connection.
        return if !sysread($parent, my $ignored, 4096);
        die "Unexpected command on IDLE channel\n";
      }
      my $n = $socket->sysread(my $chunk, 8192);
      die "IDLE connection closed\n" unless defined $n && $n > 0;
      $buffer .= $chunk;
      die "IDLE response too large\n" if length($buffer) > 65536;
      while ($buffer =~ s/^(.*?)\r?\n//) {
        my $line = $1;
        die "IDLE server closed connection\n" if $line =~ /^\* BYE\b/i;
        if ($state eq 'continuation' && $line =~ /^\+/) {
          $state = 'idle'; $refresh = time() + $renew;
          $next_heartbeat = time() + $heartbeat;
          $on_status->(1); $on_change->(); # catch arrivals during reconnect
        } elsif ($line =~ /^\Q$tag\E (\S+)/i) {
          die "IDLE refused\n" unless $state eq 'completion' && uc($1) eq 'OK';
          $start->();
        } elsif ($line =~ /^\* (?:\d+ (?:EXISTS|EXPUNGE|FETCH)\b|VANISHED\b)/i) {
          $on_change->();
        }
      }
    }
  }
}
1;
