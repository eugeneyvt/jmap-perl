package JMAP::RuntimeHealth;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use JMAP::RuntimePolicy;

my %stages = map {$_ => 1} qw(queue sql lock transaction imap smtp mime cache_write);
my %counters = map {$_ => 1} qw(cache_corrupt notification_failed smtp_unknown);
sub new { bless {timings=>{}, counters=>{}, exits=>{}, requests=>0, rejected=>0, expired=>0}, $_[0] }
sub ingest {
  my ($self, $name, $data) = @_;
  return unless ref($data) eq 'HASH';
  my $role = JMAP::RuntimePolicy::role($name);
  for my $stage (keys %{$data->{timings} || {}}) {
    next unless $stages{$stage};
    my $sample = $data->{timings}{$stage};
    next unless ref($sample) eq 'HASH';
    for my $field (qw(count seconds max_seconds)) {
      my $n = $sample->{$field} // 0;
      next unless !ref($n) && $n =~ /\A\d+(?:\.\d+)?(?:e[+-]?\d+)?\z/i;
      if ($field eq 'max_seconds') {
        $self->{timings}{$role}{$stage}{$field} = $n
          if $n > ($self->{timings}{$role}{$stage}{$field} // 0);
      } else { $self->{timings}{$role}{$stage}{$field} += $n }
    }
  }
  for my $key (keys %{$data->{counters} || {}}) {
    next unless $counters{$key};
    my $n = $data->{counters}{$key};
    next unless defined $n && !ref($n) && $n =~ /\A\d+\z/;
    $self->{counters}{$role}{$key} += $n;
  }
  if (defined $data->{free_bytes} && $data->{free_bytes} =~ /\A\d+\z/) {
    $self->{free_bytes} = 0 + $data->{free_bytes};
    $self->{free_at} = $data->{sampled_at} // time();
  }
  if (ref($data->{delivery}) eq 'HASH') {
    my $aid = $name; $aid =~ s/:(?:idle|sync|backfill|content|search)$//;
    $self->{delivery}{$aid} = {map {$_ => 0 + ($data->{delivery}{$_} // 0)} qw(pending prepared sending unknown confirmed canceled)};
  }
  if (ref($data->{replica}) eq 'HASH' && ($data->{replica}{mode}//'')=~/^(provider|shadow|local)$/) {
    my $aid=$name;$aid=~s/:(?:idle|sync|backfill|content|search)$//;
    my %sample=(mode=>$data->{replica}{mode},sampled_at=>$data->{sampled_at}//time());
    for my $field (qw(ready pending generation inventory_complete encoding_problem_documents)) {
      my $value=$data->{replica}{$field};
      $sample{$field}=0+$value if defined($value) && !ref($value) && $value=~/^\d+$/;
    }
    $self->{replica}{$aid}=\%sample;
  }
}
sub exited {
  my ($self, $name, $status) = @_;
  my $outcome = ($status & 127) ? 'signal' : ($status >> 8) ? 'error' : 'clean';
  $self->{exits}{JMAP::RuntimePolicy::role($name)}{$outcome}++;
}
sub observe_oom {
  my ($self, $kills, $now) = @_;
  $self->{last_oom_at} = $now if defined($self->{oom_kills}) && $kills > $self->{oom_kills};
  $self->{oom_kills} = $kills;
}
sub readiness {
  my ($self, %args) = @_;
  my @accounts;
  my $ready = 1;
  for my $aid (sort keys %{$args{accounts}}) {
    my $sync = $args{sync_times}{$aid};
    my $age = defined $sync ? $args{now} - $sync : undef;
    my $oldest = 0;
    for my $name ($aid, map {"$aid:$_"} qw(sync backfill idle search)) {
      my $n = $args{policy}->oldest_age($name);
      $oldest = $n if $n > $oldest;
    }
    my @reasons;
    my $replica=$self->{replica}{$aid};
    if ($replica && $replica->{mode} eq 'local') {
      push @reasons,'local_index_incomplete' unless $replica->{ready};
      push @reasons,'local_index_sample_stale' if $args{now}-$replica->{sampled_at}>120;
    }
    push @reasons, 'sync_stale' if !defined($age) || $age > $args{max_sync_age};
    push @reasons, 'request_stalled' if $oldest > $args{max_request_age};
    push @reasons, 'smtp_outcome_unknown' if $self->{delivery}{$aid}{unknown};
    for my $name ($aid, "$aid:sync", "$aid:idle") {
      push @reasons, 'worker_repeated_failures'
        if ($args{policy}{failures}{$name}{attempts} // 0) >= 3;
    }
    $ready = 0 if @reasons;
    push @accounts, {key=>substr(sha256_hex($aid),0,16), ready=>@reasons ? 0 : 1,
      sync_age_seconds=>$age, oldest_request_age_seconds=>$oldest, reasons=>\@reasons,
      delivery=>$self->{delivery}{$aid},replica=>$replica};
  }
  my @global;
  push @global, 'accounts_not_discovered' unless $args{discovered};
  push @global, 'disk_space_unknown' unless defined $self->{free_bytes};
  push @global, 'disk_sample_stale' if defined($self->{free_at}) && $args{now} - $self->{free_at} > 120;
  push @global, 'disk_space_low' if defined($self->{free_bytes}) && $self->{free_bytes} < $args{min_free_bytes};
  push @global, 'recent_oom_kill' if defined($self->{last_oom_at}) && $args{now} - $self->{last_oom_at} < 300;
  $ready = 0 if @global;
  return {ready=>$ready, reasons=>\@global, accounts=>\@accounts,
    free_bytes=>$self->{free_bytes}, index_status=>keys(%{$self->{replica}||{}}) ? 'configured' : 'not_configured'};
}
sub metrics {
  my ($self) = @_;
  my @out;
  for my $aid (sort keys %{$self->{replica}||{}}) {
    my $key=substr(sha256_hex($aid),0,16);my $replica=$self->{replica}{$aid};
    for my $field (qw(ready pending generation inventory_complete encoding_problem_documents)) {
      push @out,'jmap_replica_'.$field.'{account_key="'.$key.'"} '.$replica->{$field} if defined $replica->{$field};
    }
  }
  for my $role (sort keys %{$self->{timings}}) {
    for my $stage (sort keys %{$self->{timings}{$role}}) {
      my $t = $self->{timings}{$role}{$stage};
      my $labels = qq{role="$role",stage="$stage"};
      push @out, qq{jmap_operation_seconds_sum{$labels} } . ($t->{seconds} // 0),
        qq{jmap_operation_seconds_count{$labels} } . ($t->{count} // 0),
        qq{jmap_operation_seconds_max{$labels} } . ($t->{max_seconds} // 0);
    }
  }
  for my $role (sort keys %{$self->{counters}}) {
    push @out, qq{jmap_$_\_total{role="$role"} $self->{counters}{$role}{$_}}
      for sort keys %{$self->{counters}{$role}};
  }
  for my $role (sort keys %{$self->{exits}}) {
    push @out, qq{jmap_worker_exits_total{role="$role",outcome="$_"} $self->{exits}{$role}{$_}}
      for sort keys %{$self->{exits}{$role}};
  }
  push @out, "jmap_backend_admitted_total $self->{requests}",
    "jmap_backend_rejected_total $self->{rejected}",
    "jmap_backend_read_timeouts_total $self->{expired}";
  return @out;
}
1;
