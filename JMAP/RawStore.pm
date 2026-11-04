package JMAP::RawStore;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempfile);
use File::Spec;
use Cwd qw(abs_path);
use IO::Handle;
use File::Basename qw(dirname);
use JMAP::AtomicFile;

# Only the isolated replica worker touches this adapter. HTTP/search workers
# must never call it to enumerate, test existence, or validate search results.
sub new {
  my ($class,%args)=@_;
  die "Explicit absolute raw root required\n" unless ($args{root}//'') =~ m{^/};
  die "Explicit mount guard required\n" unless ref($args{guard}) eq 'CODE';
  die "Explicit account required\n" unless length($args{account}//'');
  return bless {%args,account_key=>sha256_hex($args{account})},$class;
}

sub _root {
  my ($self)=@_;
  $self->{guard}->() or die "Raw store mount unavailable\n";
  my $root=$self->{root};
  die "Raw store root unavailable\n" unless -d $root && !-l $root;
  my $real=abs_path($root);
  die "Raw store root changed\n" unless defined($real) && $real eq $root;
  return $root;
}

sub _path {
  my ($self,$hash,$create)=@_;
  die "Invalid content hash\n" unless defined($hash) && $hash =~ /^[a-f0-9]{64}$/;
  my $dir=$self->_root;
  for my $component ($self->{account_key},substr($hash,0,2)) {
    $dir=File::Spec->catdir($dir,$component);
    JMAP::AtomicFile->ensure_directory($dir) if $create;
    die "Unsafe raw store directory\n" if -l $dir;
  }
  return File::Spec->catfile($dir,"$hash.eml");
}

sub digest_file {
  my ($class,$path)=@_;
  open my $f,'<:raw',$path or die "Raw read unavailable\n";
  my $sha=Digest::SHA->new(256);my $bytes=0;
  while (1) {
    my $n=read($f,my $buf,131072);
    die "Raw read failed\n" unless defined $n;
    last unless $n;
    $bytes+=$n;$sha->add($buf);
  }
  close($f) or die "Raw close failed\n";
  return ($sha->hexdigest,$bytes);
}

sub verified_path {
  my ($self,$hash,$bytes)=@_;
  my $path=$self->_path($hash,0);
  die "Raw object missing\n" unless -f $path && !-l $path;
  my ($actual,$size)=__PACKAGE__->digest_file($path);
  die "Raw object checksum mismatch\n" unless $actual eq $hash && $size==$bytes;
  return $path;
}

sub publish {
  my ($self,$source,$expected_bytes)=@_;
  my ($hash,$bytes)=__PACKAGE__->digest_file($source);
  die "Incomplete raw source\n" unless $bytes==$expected_bytes;
  my $path=$self->_path($hash,1);
  if (-e $path) { $self->verified_path($hash,$bytes);return {sha256=>$hash,bytes=>$bytes} }
  my ($out,$temp)=tempfile('.jmap-raw-XXXXXXXX',DIR=>dirname($path),UNLINK=>0);
  my $ok=eval {
    binmode $out;
    open my $in,'<:raw',$source or die "Raw source unavailable\n";
    my $copied=0;
    while (1) {
      my $n=read($in,my $buf,131072);die "Raw source read failed\n" unless defined $n;last unless $n;
      $copied+=$n;die "Raw source grew beyond manifest\n" if $copied>$bytes;
      print {$out} $buf or die "Raw store write failed\n";
    }
    close($in) or die "Raw source close failed\n";
    $out->sync or die "Raw store fsync failed\n";
    close($out) or die "Raw store close failed\n";
    my ($written,$size)=__PACKAGE__->digest_file($temp);
    die "Raw store verification failed\n" unless $written eq $hash && $size==$bytes;
    $self->_root; # never publish after a detected mount loss
    rename($temp,$path) or die "Raw store publish failed\n";
    JMAP::AtomicFile::_sync_directory(dirname($path));
    $self->verified_path($hash,$bytes); # server-side rename is not sufficient proof
    1;
  };
  my $error=$@;
  unless ($ok) {close($out) if defined fileno($out);unlink($temp);die $error}
  return {sha256=>$hash,bytes=>$bytes};
}
1;
