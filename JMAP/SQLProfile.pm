package JMAP::SQLProfile;
use strict;
use warnings;
use parent 'DBI::Profile';
use JMAP::Telemetry;

# Do not retain statements/binds and do not print a profile during destruction.
sub new { shift->SUPER::new(Path => ['!MethodName']) }
sub DESTROY { }
sub collect {
  my ($self) = @_;
  for my $sample (values %{$self->{Data} || {}}) {
    next unless ref($sample) eq 'ARRAY';
    JMAP::Telemetry::record('sql', $sample->[1] // 0, $sample->[0], $sample->[4]);
  }
  $self->{Data} = {};
}
1;
