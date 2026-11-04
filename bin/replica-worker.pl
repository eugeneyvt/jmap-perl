#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Spec;
use Fcntl qw(:flock);
use JSON::XS qw(encode_json);
use Digest::SHA qw(sha256_hex);
use JMAP::ImapDB;
use JMAP::Replica;
use JMAP::RawStore;
use JMAP::ReplicaWorker;
use JMAP::StorageBox;

# Deliberately bounded command for a separate supervised container. Never run
# inside the HTTP worker. Deployment must mount the same SSD /data and a guarded
# Box subtree, with its own memory/CPU/pids/spool budgets and process deadline.
my ($account,$raw_root,$mount,$marker,$marker_sha,$inventory);
my ($max_messages,$max_bytes,$max_seconds,$metadata_steps)=(25,67108864,120,10);
GetOptions('account=s'=>\$account,'raw-root=s'=>\$raw_root,'mount=s'=>\$mount,
  'marker=s'=>\$marker,'marker-sha256=s'=>\$marker_sha,'inventory'=>\$inventory,
  'max-messages=i'=>\$max_messages,'max-bytes=i'=>\$max_bytes,'max-seconds=i'=>\$max_seconds,
  'metadata-steps=i'=>\$metadata_steps) or die "Invalid replica arguments\n";
die "Explicit safe account required\n" unless ($account//'')=~/^[a-zA-Z0-9_-]+$/;
die "Explicit raw storage configuration required\n" unless defined($raw_root) && defined($mount) && defined($marker) && ($marker_sha//'')=~/^[a-f0-9]{64}$/;
die "Invalid replica budget\n" unless $max_messages>0 && $max_bytes>0 && $max_seconds>0 && $metadata_steps>0;
die "Replica storage must be below its mount\n" unless index($raw_root,"$mount/")==0 && index($marker,"$mount/")==0;
my $base=File::Spec->catdir($JMAP::DB::DATADIR,$account);
die "Existing account required\n" unless -f "$JMAP::DB::DATADIR/$account.sqlite3";
JMAP::AtomicFile->ensure_directory($base);
open my $lock,'>>',"$base/replica-worker.lock" or die "Replica lock unavailable\n";
flock($lock,LOCK_EX|LOCK_NB) or die "Replica worker already running\n";
my $started=time();
# alarm is a useful application deadline; supervisor/container deadlines are
# also required because FUSE operations can be stuck in kernel I/O.
$SIG{ALRM}=sub {die "Replica run deadline exceeded\n"};alarm($max_seconds);
my $store=JMAP::StorageBox->from_config(root=>$raw_root,mount=>$mount,marker=>$marker,marker_sha=>$marker_sha,account=>$account);
$store->_root;
my $db=JMAP::ImapDB->new($account);
my $replica=JMAP::Replica->new(path=>"$base/replica.sqlite3");
my $spool="$base/replica-spool";JMAP::AtomicFile->ensure_directory($spool);

if ($inventory) {
  # LIST all selectable folders. Gmail label copies retain X-GM-MSGID; Spam
  # and Trash are not omitted just because All Mail exists.
  $db->sync_folders;
  $db->begin_read;my $folders=$db->dbh->selectall_arrayref('SELECT * FROM ifolders ORDER BY ifolderid',{Slice=>{}});$db->commit;
  my %checked=map {$_->[0]=>$_->[1]} @{$replica->{dbh}->selectall_arrayref('SELECT folder,checked FROM replica_scopes')};
  # Rotate across every selectable folder, including accounts with more folders
  # than one run's metadata budget. A large Inbox cannot starve later folders.
  @$folders=sort {($checked{$a->{ifolderid}}//0)<=>($checked{$b->{ifolderid}}//0) || $a->{ifolderid}<=>$b->{ifolderid}} @$folders;
  my $steps=0;
  for my $folder (@$folders) {
    last if $steps >= $metadata_steps;
    my $label=($db->{is_gmail} && lc($folder->{label}//'') eq '\\allmail') ? undef : $folder->{label};
    $db->do_folder($folder->{ifolderid},$label);$steps++;
    my $folder_steps=0;
    while ($steps<$metadata_steps && $folder_steps<2) {
      $db->begin_read;my $f=$db->dgetone('ifolders',{ifolderid=>$folder->{ifolderid}});$db->commit;
      last if $f->{uidfirst}<=1;
      $db->do_folder($f->{ifolderid},$label,500);$steps++;$folder_steps++;
    }
    $db->begin_read;my $current=$db->dgetone('ifolders',{ifolderid=>$folder->{ifolderid}});$db->commit;
    $replica->{dbh}->do('INSERT OR REPLACE INTO replica_scopes(folder,uidvalidity,uidnext,uidfirst,checked) VALUES(?,?,?,?,?)',{},
      @$current{qw(ifolderid uidvalidity uidnext uidfirst)},time());
  }
  $db->sync_jmap;
}

# Copy a bounded metadata cursor into the durable queue. No raw bytes, provider
# calls or Box operations happen while holding the account read transaction.
$replica->reconcile_catalog($db);
my $worker=JMAP::ReplicaWorker->new(db=>$db,replica=>$replica,store=>$store,spool=>$spool);
my ($done,$bytes,$failed)=(0,0,0);
while ($done+$failed<$max_messages && time()-$started<$max_seconds) {
  my $job=$replica->claim(lease=>$max_seconds+30);last unless $job;
  if ($bytes+$job->{bytes}>$max_bytes) {$replica->fail($job,'run_byte_budget');$failed++;next}
  # Raw input + MIME parser scratch + decoded parts must fit without consuming
  # the account/outbox reserve. This is SSD admission only; never df the Box
  # while holding an account lock or serving a search.
  open my $df,'-|','df','-Pk',$spool or die "Spool capacity unavailable\n";
  my @lines=<$df>;close $df;my @fields=split /\s+/,($lines[-1]//'');
  my $available=@fields>=6 && $fields[3]=~/^\d+$/ ? 1024*$fields[3] : 0;
  if ($available<1073741824+4*$job->{bytes}) {$replica->fail($job,'spool_space_low');$failed++;last}
  my $result=$worker->process($job);
  $bytes+=$job->{bytes};$result->{ok} ? $done++ : $failed++;
}
alarm(0);
my $reconciled=$replica->reconcile_catalog($db);
my $complete=@{$reconciled->{scopes}} && !$reconciled->{missing} ? 1 : 0;
for my $folder (@{$reconciled->{scopes}}) {
  my $scope=$replica->{dbh}->selectrow_hashref('SELECT * FROM replica_scopes WHERE folder=?',{},$folder->{ifolderid});
  $complete=0 unless $scope && $scope->{uidfirst}<=1 && $scope->{uidvalidity}==$folder->{uidvalidity}
    && $scope->{uidnext}==$folder->{uidnext} && time()-$scope->{checked}<1800;
}
$replica->seal_catalog($reconciled->{token},$complete);
print encode_json({completed=>$done,failed=>$failed,bytes=>$bytes,elapsed_seconds=>time()-$started}),"\n";
exit($failed ? 2 : 0);
