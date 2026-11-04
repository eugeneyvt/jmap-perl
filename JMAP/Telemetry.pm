package JMAP::Telemetry;
use strict;
use warnings;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

# Fixed labels only. Neither SQL text, IMAP arguments, account addresses nor
# request arguments may become metric labels. State is process-local after fork.
my %allowed = map { $_ => 1 } qw(queue sql lock transaction imap smtp mime cache_write);
my (%timings, %counters);
my $owner = $$;
sub _pid {
  return if $owner == $$;
  %timings = (); %counters = (); $owner = $$;
}
sub now { clock_gettime(CLOCK_MONOTONIC) }
sub record {
  my ($name, $seconds, $count, $maximum) = @_;
  _pid();
  die "Unknown metric\n" unless $allowed{$name};
  $seconds = 0 if $seconds < 0;
  $timings{$name}{count} += $count // 1;
  $timings{$name}{seconds} += $seconds;
  $maximum //= $seconds;
  $timings{$name}{max_seconds} = $maximum
    if $maximum > ($timings{$name}{max_seconds} // 0);
}
sub increment {
  my ($name) = @_;
  _pid();
  die "Unknown counter\n" unless $name =~ /\A(?:cache_corrupt|notification_failed|smtp_unknown)\z/;
  $counters{$name}++;
}
sub measure {
  my ($name, $code) = @_;
  my $t = now();
  my $context = wantarray;
  my (@result, $result);
  my $ok = eval {
    if (!defined $context) { $code->() }
    elsif ($context) { @result = $code->() }
    else { $result = $code->() }
    1;
  };
  my $error = $@;
  record($name, now() - $t);
  die $error unless $ok;
  return $context ? @result : $result;
}
sub drain {
  _pid();
  my $out = {timings => {%timings}, counters => {%counters}};
  %timings = (); %counters = ();
  return $out;
}
1;
