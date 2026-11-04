#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use JSON::XS qw(encode_json);
use Digest::SHA qw(sha256_hex);
use DBI;
use DBD::SQLite::Constants qw(SQLITE_OPEN_READONLY);
use JMAP::Replica;

# Status is strictly read-only, including the account DB (no constructor
# migrations). Switching mode mutates only the prepared replica's SSD state.
my ($root,$account,$mode);
GetOptions('data-dir=s'=>\$root,'account=s'=>\$account,'mode=s'=>\$mode)
  or die "Invalid replica control arguments\n";
die "Explicit account and data directory required\n" unless defined($root) && ($account//'')=~/^[a-zA-Z0-9_-]+$/;
die "Existing replica required\n" unless -f "$root/$account/replica.sqlite3";
my $db=DBI->connect("dbi:SQLite:dbname=$root/$account.sqlite3",undef,undef,
  {RaiseError=>1,PrintError=>0,sqlite_open_flags=>SQLITE_OPEN_READONLY,sqlite_use_immediate_transaction=>0});
$db->begin_work;
my ($generation)=$db->selectrow_array('SELECT generation FROM jreplicacatalog WHERE singleton=1');
my $folders=$db->selectall_arrayref('SELECT ifolderid,uidvalidity,uidfirst,uidnext FROM ifolders ORDER BY ifolderid');
my $json=JSON::XS->new->canonical->utf8;
my $token=sha256_hex($json->encode([$generation,$folders]));
$db->commit;
my $r=JMAP::Replica->new(path=>"$root/$account/replica.sqlite3",read_only=>defined($mode)?0:1);
$r->set_mode($mode,$token) if defined $mode;
my $status=$r->coverage($token);
$status->{jobs}=$r->{dbh}->selectall_arrayref('SELECT state,count(*) AS count,COALESCE(sum(bytes),0) AS bytes FROM replica_jobs GROUP BY state',{Slice=>{}});
$status->{failures}=$r->{dbh}->selectall_arrayref('SELECT error_code,count(*) AS count FROM replica_jobs WHERE error_code IS NOT NULL GROUP BY error_code',{Slice=>{}});
$status->{account_key}=substr(sha256_hex($account),0,16);
delete $status->{catalog_state};
print encode_json($status),"\n";
