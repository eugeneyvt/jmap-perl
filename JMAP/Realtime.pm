package JMAP::Realtime;
use strict;
use warnings;

sub account_id { my $id = $_[0]; $id =~ s/:[^:]+$//; return $id }
sub state_event {
  my ($worker, $states) = @_;
  return { '@type' => 'StateChange', changed => { account_id($worker) => $states } };
}
sub idle_healthy {
  my ($entry, $now) = @_;
  return $entry && $entry->{active} && $now - ($entry->{heartbeat} // 0) < 45;
}
sub needs_poll {
  my ($entry, $last_sync, $now, $fallback) = @_;
  return !idle_healthy($entry, $now) || $now - ($last_sync // 0) >= $fallback;
}
sub merge_state {
  my ($pending, $event) = @_;
  for my $aid (keys %{$event->{changed} || {}}) {
    for my $kind (keys %{$event->{changed}{$aid}}) {
      $pending->{$aid}{$kind} = $event->{changed}{$aid}{$kind};
    }
  }
}
1;
