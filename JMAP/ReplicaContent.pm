package JMAP::ReplicaContent;
use strict;
use warnings;
use MIME::Parser;
use File::Temp;
use JMAP::StorageBox;
use JMAP::ContentCache;

sub download {
  my ($class,$db,$blob)=@_;
  return unless $blob=~/^m-([^-]+)(?:-([0-9]+(?:\.[0-9]+)*))?$/;
  my ($id,$part)=($1,$2);
  my $replica=$db->local_replica or return;
  my $manifest=$replica->{dbh}->selectrow_hashref("SELECT sha256,bytes FROM replica_jobs WHERE msgid=? AND state='complete' LIMIT 1",{},$id);
  return unless $manifest;
  my $base="$JMAP::DB::DATADIR/".$db->accountid;
  my $cache="$base/replica-cache";JMAP::AtomicFile->ensure_directory($cache);
  my $hot=JMAP::ContentCache->new(root=>$cache,max_bytes=>$ENV{JMAP_RAW_CACHE_BYTES}//268435456);
  # Obtain the cache hit before constructing or checking the remote adapter.
  my $raw=$hot->get($manifest->{sha256},$manifest->{bytes});
  unless ($raw) {
    my $store=JMAP::StorageBox->from_env($db->accountid);
    $raw=$hot->obtain($store,$manifest->{sha256},$manifest->{bytes});
  }
  return {file=>$raw,bytes=>$manifest->{bytes},type=>'message/rfc822',ephemeral=>0} unless defined $part;
  my $spool="$base/replica-content";JMAP::AtomicFile->ensure_directory($spool);
  my $temporary=File::Temp->newdir('mime-XXXXXXXX',DIR=>$spool,CLEANUP=>1);
  my $parser=MIME::Parser->new;
  $parser->output_under("$temporary");$parser->tmp_dir("$temporary");
  $parser->output_to_core(0);$parser->tmp_to_core(0);$parser->max_parts(1000);
  $parser->extract_nested_messages(0);$parser->ignore_errors(0);
  my $entity;
  {
    local $MIME::Decoder::DecoderFor{'7bit'}='MIME::Decoder::Binary';
    local $MIME::Decoder::DecoderFor{'8bit'}='MIME::Decoder::Binary';
    $entity=$parser->parse_open($raw) or die "Replica attachment parse failed\n";
  }
  my @numbers=split /\./,$part;
  if ($entity->parts) {
    for my $number (@numbers) {
      my @parts=$entity->parts;
      die "Replica attachment not found\n" unless $number>0 && $number<=@parts;
      $entity=$parts[$number-1];
    }
  } else {die "Replica attachment not found\n" unless $part eq '1'}
  die "Replica attachment is multipart\n" if $entity->parts;
  my $handle=$entity->bodyhandle or die "Replica attachment missing\n";
  my ($out,$path)=File::Temp::tempfile('download-XXXXXXXX',DIR=>$spool,UNLINK=>0);binmode $out;
  my $ok=eval {
    my $in=$handle->open('r') or die "Replica attachment unavailable\n";
    my $bytes=0;
    while (1) {my $n=$in->read(my $buf,131072);die "Replica attachment read failed\n" unless defined $n;last unless $n;
      $bytes+=$n;die "Replica attachment budget exceeded\n" if $bytes>$manifest->{bytes};
      print {$out} $buf or die "Replica attachment spool failed\n"}
    $in->close;$out->sync or die "Replica attachment fsync failed\n";
    close($out) or die "Replica attachment close failed\n";
    {file=>$path,bytes=>$bytes,type=>$entity->effective_type,ephemeral=>1};
  };
  my $error=$@;
  unless ($ok) {close($out) if defined fileno($out);unlink($path);die $error}
  return $ok;
}
1;
