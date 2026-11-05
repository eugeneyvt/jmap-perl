package JMAP::ContentCache;
use strict;
use warnings;
use File::Temp qw(tempfile);
use IO::Handle;
use JMAP::AtomicFile;
use JMAP::RawStore;

# Bounded SSD hot raw cache. Only a dedicated content worker may populate it.
# Cache hits never examine or stat Storage Box. Evictions affect this adapter's
# own verified disposable files, never originals, outbox or parser evidence.
sub new {
  my ($class,%args)=@_;
  die "Explicit cache directory required\n" unless defined $args{root} && -d $args{root} && !-l $args{root};
  $args{max_bytes}//=268435456;$args{max_files}//=128;
  die "Invalid content cache limit\n" unless $args{max_bytes}>0 && $args{max_files}>0;
  return bless \%args,$class;
}

sub _path {
  my ($self,$hash)=@_;
  die "Invalid content hash\n" unless ($hash//'')=~/^[a-f0-9]{64}$/;
  return "$self->{root}/$hash.eml";
}

sub get {
  my ($self,$hash,$bytes)=@_;my $path=$self->_path($hash);
  return unless -f $path && !-l $path;
  my ($actual,$size)=JMAP::RawStore->digest_file($path);
  return unless $actual eq $hash && $size==$bytes;
  utime(undef,undef,$path) or die "Content cache age update failed\n";
  return $path;
}

sub obtain {
  my ($self,$store,$hash,$bytes)=@_;
  die "Original exceeds content cache budget\n" if $bytes>$self->{max_bytes};
  if (my $hit=$self->get($hash,$bytes)) {return $hit}
  my $source=$store->verified_path($hash,$bytes);
  my $path=$self->_path($hash);
  opendir my $directory,$self->{root} or die "Content cache unavailable\n";
  my @files;
  while (my $name=readdir($directory)) {
    next unless $name=~/^[a-f0-9]{64}\.eml$/;
    my $file="$self->{root}/$name";next if -l $file;
    my @stat=stat($file);push @files,{path=>$file,bytes=>$stat[7],age=>$stat[9]} if @stat;
  }
  closedir $directory;
  @files=sort {$a->{age}<=>$b->{age} || $a->{path} cmp $b->{path}} @files;
  my $used=0;$used+=$_->{bytes} for @files;
  while (@files && ($used+$bytes>$self->{max_bytes} || @files>=$self->{max_files})) {
    my $old=shift @files;unlink($old->{path}) or die "Content cache eviction failed\n";$used-=$old->{bytes};
  }
  my ($out,$temp)=tempfile('.jmap-hot-XXXXXXXX',DIR=>$self->{root},UNLINK=>0);binmode $out;
  my $ok=eval {
    open my $in,'<:raw',$source or die "Original unavailable\n";
    my $copied=0;
    while (1) {my $n=read($in,my $buf,131072);die "Original read failed\n" unless defined $n;last unless $n;
      $copied+=$n;die "Original grew beyond manifest\n" if $copied>$bytes;
      print {$out} $buf or die "Content cache write failed\n"}
    close($in) or die "Original close failed\n";
    $out->sync or die "Content cache fsync failed\n";close($out) or die "Content cache close failed\n";
    my ($actual,$size)=JMAP::RawStore->digest_file($temp);
    die "Content cache checksum mismatch\n" unless $actual eq $hash && $size==$bytes;
    rename($temp,$path) or die "Content cache publish failed\n";
    JMAP::AtomicFile::_sync_directory($self->{root});1;
  };
  my $error=$@;
  unless ($ok) {close($out) if defined fileno($out);unlink($temp);die $error}
  return $path;
}
1;
