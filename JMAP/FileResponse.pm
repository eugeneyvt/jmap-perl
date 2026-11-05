package JMAP::FileResponse;
use strict;
use warnings;

# Validate a worker's local SSD descriptor before opening it in the parent.
# Body callbacks deliver one bounded chunk per writable HTTP queue turn.
sub prepare {
  my ($class,$root,$account,$descriptor)=@_;
  die "Invalid download account\n" unless $account=~/^[a-zA-Z0-9_-]+$/;
  my $file=$descriptor->{file}//'';
  my $cache="$root/$account/replica-cache/";
  my $scratch="$root/$account/replica-content/";
  my $ephemeral=$descriptor->{ephemeral}?1:0;
  die "Invalid download path\n" unless $ephemeral
    ? $file=~/^\Q$scratch\Edownload-[a-zA-Z0-9_]+$/
    : $file=~/^\Q$cache\E[a-f0-9]{64}\.eml$/;
  die "Download file unavailable\n" unless -f $file && !-l $file;
  open my $f,'<:raw',$file or die "Download file unavailable\n";
  my $bytes=-s $f;
  die "Download length changed\n" unless defined($descriptor->{bytes}) && $bytes==$descriptor->{bytes};
  # Unlink private, single-response staging after opening: the fd survives
  # client disconnect/worker death, and no named orphan needs a cleanup job.
  unlink($file) or die "Cannot release download staging\n" if $ephemeral;
  my $closed=0;
  my $body=sub {
    my ($deliver)=@_;
    unless ($deliver) {close($f) unless $closed++;return}
    return $deliver->('') if $closed;
    my $n=read($f,my $chunk,65536);
    unless (defined($n) && $n>0) {close($f);$closed=1;return $deliver->('')}
    $deliver->($chunk);
  };
  return ($bytes,$body);
}
1;
