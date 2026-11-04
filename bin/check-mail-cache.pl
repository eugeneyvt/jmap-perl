#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Spec;
use DBI;
use DBD::SQLite::Constants qw(SQLITE_OPEN_READONLY);
use JSON::XS qw(decode_json encode_json);
use Digest::SHA qw(sha256_hex);

# Read-only audit. Do not instantiate JMAP::DB (its constructor migrates).
# No cache cleanup, checkpoint advancement or provider connection occurs here.
my ($root,$account);
my $max_json=16*1024*1024;
GetOptions('data-dir=s'=>\$root,'account=s'=>\$account,'max-json-bytes=i'=>\$max_json)
  or die "Invalid audit arguments\n";
die "Explicit --data-dir and --account required\n" unless defined($root) && defined($account);
die "Invalid account path\n" if $account =~ m{[/\\]} || $account eq '.' || $account eq '..';
die "Invalid JSON memory budget\n" unless $max_json>0;
my $path=File::Spec->catfile($root,"$account.sqlite3");
die "Account database does not exist\n" unless -f $path;
my $db=DBI->connect("dbi:SQLite:dbname=$path",undef,undef,
  {sqlite_open_flags=>SQLITE_OPEN_READONLY,RaiseError=>1,PrintError=>0});
$db->do('PRAGMA query_only=ON');
my $r={read_only=>JSON::XS::true,account_key=>substr(sha256_hex($account),0,16),
  parsed=>{files=>0,valid=>0,invalid=>0,over_budget=>0,not_in_catalog=>0,metadata_without_file=>0},
  outbox=>{manifest_rows=>0,missing=>0,hash_mismatch=>0,legacy_unverified=>0,orphan_files=>0},
  staging_files=>0,raw_mirror=>'not_implemented'};
my $base=File::Spec->catdir($root,$account);
my $replica_path=File::Spec->catfile($base,'replica.sqlite3');
my $replica;
if (-f $replica_path) {
  require JMAP::Replica;
  $replica=JMAP::Replica->new(path=>$replica_path,read_only=>1);
  $r->{raw_mirror}={mode=>$replica->state->{mode},
    jobs=>$replica->{dbh}->selectall_arrayref('SELECT state,count(*),coalesce(sum(bytes),0) FROM replica_jobs GROUP BY state'),
    indexed=>0+$replica->{dbh}->selectrow_array('SELECT count(*) FROM replica_documents'),
    raw_checksums_checked=>JSON::XS::false};
}
my $parsed=File::Spec->catdir($base,'parsed');
if (-d $parsed) {
  opendir(my $dir,$parsed) or die "Cannot inspect parsed cache\n";
  while (my $name=readdir($dir)) {
    $r->{staging_files}++ if $name =~ /^\.jmap-write-/;
    next unless $name =~ /^(.*)\.json$/;
    my $id=$1;my $file=File::Spec->catfile($parsed,$name);next unless -f $file;
    $r->{parsed}{files}++;
    my ($known)=$db->selectrow_array('SELECT 1 FROM jmessages WHERE msgid=?',{},$id);
    $r->{parsed}{not_in_catalog}++ unless $known;
    if (-s $file > $max_json) {$r->{parsed}{over_budget}++;next}
    open my $f,'<:raw',$file or die "Cannot read parsed cache\n";
    my $bytes=do {local $/;<$f>};close $f;
    my $v=eval {decode_json($bytes)};
    $r->{parsed}{ref($v) eq 'HASH' ? 'valid' : 'invalid'}++;
  }
  closedir $dir;
}
my $manifest=$db->selectcol_arrayref('SELECT msgid FROM jrawmessage');
for my $id (@$manifest) {
    unless (-f File::Spec->catfile($parsed,"$id.json")) {
      my $present=0;
      if ($replica) {
        ($present)=$replica->{dbh}->selectrow_array('SELECT 1 FROM replica_documents WHERE msgid=? AND payload IS NOT NULL',{},$id);
      }
      $r->{parsed}{metadata_without_file}++ unless $present;
    }
}
my ($journal)=$db->selectrow_array("SELECT 1 FROM sqlite_master WHERE type='table' AND name='jdelivery'");
my %held;
if ($journal) {
  my $rows=$db->selectall_arrayref('SELECT jsubid,state,body_sha256 FROM jdelivery',{Slice=>{}});
  for my $row (@$rows) {
    my $id=$row->{jsubid};$held{"$id.eml"}=1;$r->{outbox}{manifest_rows}++;
    next if $row->{state} eq 'canceled';
    my $file=File::Spec->catfile($base,'outbox',"$id.eml");
    unless (-f $file) {$r->{outbox}{missing}++;next}
    unless (defined $row->{body_sha256}) {$r->{outbox}{legacy_unverified}++;next}
    open my $f,'<:raw',$file or die "Cannot read outbox cache\n";
    my $digest=Digest::SHA->new(256)->addfile($f)->hexdigest;close $f;
    $r->{outbox}{hash_mismatch}++ if $digest ne $row->{body_sha256};
  }
}
my $outbox=File::Spec->catdir($base,'outbox');
if (-d $outbox) {
  opendir(my $dir,$outbox) or die "Cannot inspect outbox cache\n";
  while (my $name=readdir($dir)) {
    $r->{staging_files}++ if $name =~ /^\.jmap-write-/;
    $r->{outbox}{orphan_files}++ if $name =~ /\.eml$/ && !$held{$name};
  }
  closedir $dir;
}
$r->{healthy}=($r->{parsed}{invalid} || $r->{parsed}{over_budget}
  || $r->{parsed}{metadata_without_file} || $r->{outbox}{missing}
  || $r->{outbox}{hash_mismatch} || $r->{outbox}{legacy_unverified}) ? JSON::XS::false : JSON::XS::true;
print encode_json($r),"\n";
exit($r->{healthy} ? 0 : 2);
