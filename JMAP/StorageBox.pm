package JMAP::StorageBox;
use strict;
use warnings;
use JMAP::RawStore;

sub from_config {
  my ($class,%args)=@_;
  for (qw(root mount marker marker_sha account)) {die "Incomplete raw storage configuration\n" unless defined($args{$_}) && length($args{$_})}
  die "Invalid raw storage mount\n" unless $args{mount}=~m{^/} && $args{marker_sha}=~/^[a-f0-9]{64}$/;
  die "Raw storage must be below mount\n" unless index($args{root},"$args{mount}/")==0 && index($args{marker},"$args{mount}/")==0;
  my $guard=sub {
    open my $mounts,'<','/proc/self/mountinfo' or die "Mount information unavailable\n";
    my $found=0;
    while (<$mounts>) {my @fields=split;$found=1 if $fields[4] eq $args{mount} && / - fuse\.sshfs /}
    close $mounts;return 0 unless $found;
    return 0 unless -f $args{marker} && !-l $args{marker} && -s $args{marker}<=4096;
    my ($hash)=JMAP::RawStore->digest_file($args{marker});return $hash eq $args{marker_sha};
  };
  return JMAP::RawStore->new(root=>$args{root},account=>$args{account},guard=>$guard);
}

sub from_env {
  my ($class,$account)=@_;
  return $class->from_config(root=>$ENV{JMAP_RAW_ROOT},mount=>$ENV{JMAP_RAW_MOUNT},
    marker=>$ENV{JMAP_RAW_MARKER},marker_sha=>$ENV{JMAP_RAW_MARKER_SHA256},account=>$account);
}
1;
