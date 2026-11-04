package JMAP::ReplicaWorker;
use strict;
use warnings;
use File::Temp qw(tempfile);
use IO::Handle;
use JMAP::RawStore;
use JMAP::ReplicaParser;

sub new {my ($class,%args)=@_;bless \%args,$class}

sub process {
  my ($self,$job)=@_;
  my ($fh,$spool)=tempfile('.jmap-download-XXXXXXXX',DIR=>$self->{spool},UNLINK=>0);
  binmode $fh;
  my $stage='fetch';
  my $ok=eval {
    my $db=$self->{db};
    $db->begin_read;
    my $folder=$db->dgetone('ifolders',{ifolderid=>$job->{folder}});
    my $mapping=$db->dgetone('imessages',{ifolderid=>$job->{folder},uid=>$job->{uid}});
    $db->commit;
    die "Replica source changed\n" unless $folder && $mapping && $folder->{uidvalidity}==$job->{uidvalidity} && $mapping->{msgid} eq $job->{msgid};
    my $alias=$db->{is_gmail} && $self->{replica}->complete_alias($job);
    unless ($alias) {
    my $stored_hash=$job->{sha256};
    if (!$stored_hash && $db->{is_gmail}) {
      # X-GM-MSGID is provider-assigned across label copies. Generic legacy
      # envelope hashes are explicitly not trusted for this optimization.
      ($stored_hash)=$self->{replica}{dbh}->selectrow_array("SELECT sha256 FROM replica_jobs
        WHERE msgid=? AND state='complete' AND bytes=? LIMIT 1",{},$job->{msgid},$job->{bytes});
    }
    if ($stored_hash) {
      # Parse retry reads the verified raw copy, not the provider again.
      $stage='storage';
      my $raw=$self->{store}->verified_path($stored_hash,$job->{bytes});
      open my $in,'<:raw',$raw or die "Raw retry unavailable\n";
      while (1) {my $n=read($in,my $buf,131072);die "Raw retry read failed\n" unless defined $n;last unless $n;print {$fh} $buf or die "Spool write failed\n"}
      close($in) or die "Raw retry close failed\n";
    } else {
      $db->backend_cmd('imap_stream_raw',$folder->{imapname},$job->{uidvalidity},$job->{uid},$job->{bytes},$fh);
    }
    $fh->sync or die "Download fsync failed\n";
    close($fh) or die "Download close failed\n";
    $stage='storage';
    my $manifest=$self->{store}->publish($spool,$job->{bytes});
    $self->{replica}->raw_saved($job,$manifest);
    $stage='parse';
    my $doc=JMAP::ReplicaParser->parse($spool,spool=>$self->{spool},msgid=>$job->{msgid});
    $stage='index';
    $self->{replica}->complete($job,$doc);
    # Publish ordinary list summaries through the existing account path. No
    # raw-store operation is performed while holding this transaction.
    my $summary_ok=eval {
      $db->begin;
      $db->cache_message_summaries({$job->{msgid}=>$doc->{parsed}});
      $db->commit;1;
    };
    # The complete SSD document remains the source for Email/get even if a
    # concurrent account writer prevents the optional list-summary update.
    eval {$db->rollback} if !$summary_ok && $db->in_transaction;
    }
    1;
  };
  my $error=$@;
  close($fh) if defined fileno($fh);
  # Only this invocation's random staging file; durable originals are immutable.
  unlink($spool) or die "Cannot remove completed download staging\n";
  unless ($ok) {
    eval {$self->{db}->rollback} if $self->{db}->in_transaction;
    my $code=$error=~/identity collision/ ? 'identity_collision' : $error=~/UIDVALIDITY|source changed|UID disappeared/ ? 'source_changed' : "${stage}_failed";
    $self->{replica}->fail($job,$code);
    return {ok=>0,error_code=>$code};
  }
  return {ok=>1,bytes=>$job->{bytes}};
}
1;
