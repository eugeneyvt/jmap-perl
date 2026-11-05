package JMAP::RuntimePolicy;
use strict;
use warnings;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

# Pure policy: the parent owns process lifecycle, this module bounds admission
# and tracks age/backoff without an unbounded per-request history.
sub new {
  my ($class, %args) = @_;
  my $self = bless {max_workers => 16, per_worker => 4, max_pending => 64,
    max_bytes => 32_000_000, read_timeout => 60, background_timeout=>180, pending => {}, failures => {},
    clock => sub { clock_gettime(CLOCK_MONOTONIC) }, random => sub { rand() }, %args}, $class;
  for my $key (qw(max_workers per_worker max_pending max_bytes read_timeout background_timeout)) {
    die "Invalid runtime limit $key\n" unless defined($self->{$key}) && !ref($self->{$key})
      && $self->{$key} =~ /\A\d+(?:\.\d+)?\z/ && $self->{$key} > 0;
    die "Invalid integer runtime limit $key\n" if $key !~ /timeout$/ && $self->{$key} != int($self->{$key});
  }
  return $self;
}
sub role {
  my ($name) = @_;
  return 'accounts' if $name eq '__accounts__';
  return $1 if $name =~ /:(idle|sync|backfill|content|search)$/;
  return 'api';
}
sub safe_read {
  my ($command, $args) = @_;
  return 1 if $command =~ /\A(?:ping|getinfo|session_caps|get_settings|download|raw|fetch_blobs|sync|backfill|davsync|list_accounts|get_account|get_pool|get_needs_backfill|get_nextsends)\z/;
  return 0 unless $command eq 'jmap';
  my $calls = $args->{methodCalls};
  return 0 unless ref($calls) eq 'ARRAY' && @$calls;
  # Unknown methods are conservatively treated as mutations. Copy, upload,
  # refreshSynced and MDN/send must never become cancellable reads.
  for my $call (@$calls) {
    return 0 unless ref($call) eq 'ARRAY' && defined $call->[0];
    return 0 unless $call->[0] =~ /\A(?:Core\/echo|(?:Email|Thread|Mailbox|Identity|EmailSubmission|Quota|Principal|Calendar|CalendarEvent|ParticipantIdentity|CalendarEventNotification|AddressBook|Addressbook|ContactCard|Contact|ContactGroup|FileNode|Blob|SearchSnippet)\/(?:get|query|changes|queryChanges|parse))\z/;
  }
  return 1;
}
sub _filter_has_provider_term {
  my ($filter) = @_;
  return 0 unless ref($filter) eq 'HASH';
  return 1 if grep { exists $filter->{$_} } qw(text from to cc bcc subject body header);
  return scalar(grep { _filter_has_provider_term($_) } @{$filter->{conditions}})
    if ref($filter->{conditions}) eq 'ARRAY';
  return 0;
}
sub provider_search {
  my ($command, $args) = @_;
  return 0 unless $command eq 'jmap' && safe_read($command, $args);
  for my $call (@{$args->{methodCalls}}) {
    return 1 if $call->[0] =~ m{\AEmail/(?:query|queryChanges)\z}
      && ref($call->[1]) eq 'HASH' && _filter_has_provider_term($call->[1]{filter});
  }
  return 0;
}
sub now { $_[0]{clock}->() }
sub admission {
  my ($self, $name, $bytes, $workers, $existing) = @_;
  my $pending = $self->{pending};
  return 'worker limit' if !$existing && $workers >= $self->{max_workers};
  return 'worker backoff' if !$existing && ($self->{failures}{$name}{retry_at} // 0) > $self->now;
  return 'worker queue full' if scalar(grep { $_->{name} eq $name } values %$pending) >= $self->{per_worker};
  return 'global queue full' if keys(%$pending) >= $self->{max_pending};
  my $used = 0; $used += $_->{bytes} for values %$pending;
  return 'queue byte limit' if $used + $bytes > $self->{max_bytes};
  return undef;
}
sub add {
  my ($self, $tag, $name, $command, $args, $bytes) = @_;
  $self->{pending}{$tag} = {name => $name, role => role($name), bytes => $bytes,
    started => $self->now, safe => safe_read($command, $args)};
}
sub finish { delete $_[0]{pending}{$_[1]} }
sub all_safe {
  my ($self, $name) = @_;
  my @p = grep { $_->{name} eq $name } values %{$self->{pending}};
  return @p && !grep { !$_->{safe} } @p;
}
sub oldest_age {
  my ($self, $name) = @_;
  my $age = 0;
  for my $p (values %{$self->{pending}}) {
    next if defined($name) && $p->{name} ne $name;
    my $n = $self->now - $p->{started}; $age = $n if $n > $age;
  }
  return $age;
}
sub failed {
  my ($self, $name) = @_;
  my $f = $self->{failures}{$name} ||= {};
  $f->{attempts} = ($f->{attempts} // 0) + 1;
  $f->{attempts} = 6 if $f->{attempts} > 6;
  $f->{retry_at} = $self->now + (2 ** ($f->{attempts} - 1)) * (1 + $self->{random}->());
}
sub succeeded { delete $_[0]{failures}{$_[1]} }
sub forget { delete $_[0]{failures}{$_[1]} }
1;
