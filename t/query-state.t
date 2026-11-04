use strict;
use warnings;
use Test::More;
use JSON::XS qw(encode_json);
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='b'x64}
use JMAP::ImapDB;
use JMAP::API;
my $db=JMAP::ImapDB->new('states');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
$db->begin;
for my $i (1..12) {
  $db->dmake('jmessages',{msgid=>"m$i",thrid=>"t$i",internaldate=>$i,keywords=>'{}'});
  $db->dmake('jmessagemap',{msgid=>"m$i",jmailboxid=>'inbox'});
}
$db->commit;
my $api=JMAP::API->new($db);
my $builds=0;my $connection=$db->_connection;
$connection->{Callbacks}={do=>sub {$builds++ if $_[1]=~/INSERT INTO temp.jmap_query_build/;return}};
sub args {return {accountId=>'states',filter=>{inMailbox=>'inbox'},sort=>[{property=>'receivedAt',isAscending=>JSON::XS::false}],@_}}
my $first=$api->api_Email_query(args(limit=>3));
is($builds,1,'first state builds one SQL snapshot');
for my $position (3,6,9) {$api->api_Email_query(args(position=>$position,limit=>3))}
is($builds,1,'other pages reuse the snapshot without rebuilding or loading full metadata');
my @cached=(map {"m$_"} reverse 1..12);
$db->begin;
$db->ddirty('jmessagemap',{active=>0},{jmailboxid=>'inbox',msgid=>'m11'});
$db->dmake('jmessages',{msgid=>'new',thrid=>'new',internaldate=>99,keywords=>'{}'});
$db->dmake('jmessagemap',{msgid=>'new',jmailboxid=>'inbox'});
$db->ddirty('jmessages',{keywords=>encode_json({'$seen'=>1})},{msgid=>'m5'});
$db->commit;
my $changes=$api->api_Email_queryChanges(args(sinceQueryState=>$first->[1]{queryState},calculateTotal=>JSON::XS::true));
is($changes->[0],'Email/queryChanges','SQL queryChanges succeeds');
my %removed=map {$_=>1} @{$changes->[1]{removed}};
@cached=grep {!$removed{$_}} @cached;
for my $added (@{$changes->[1]{added}}) {splice @cached,$added->{index},0,$added->{id}}
my $current=$api->api_Email_query(args());
is_deeply(\@cached,$current->[1]{ids},'applying removed/added reconstructs exact current ordering');
ok($removed{m5},'mutable-query changed object is removed and reinserted');
is($changes->[1]{total},12,'queryChanges total includes collapsed/filter semantics');
my $zero=$api->api_Email_queryChanges(args(sinceQueryState=>$first->[1]{queryState},maxChanges=>0));
is($zero->[1]{type},'tooManyChanges','maxChanges zero is enforced before returning any partial diff');
my $stable=$api->api_Email_queryChanges(args(sinceQueryState=>$current->[1]{queryState}));
is_deeply($stable->[1]{added},[],'unchanged state adds nothing');
ok(!exists $stable->[1]{total},'queryChanges total omitted unless requested');
$db->begin;$db->advance_search_generation;$db->commit;
my $indexed=$api->api_Email_query(args(limit=>1));
isnt($indexed->[1]{queryState},$current->[1]{queryState},'new searchable content generation invalidates state without a move');
my $scoped=JMAP::API->new($db);$scoped->{query_scope}='different-authorized-scope';
isnt($scoped->api_Email_query(args(limit=>1))->[1]{queryState},$indexed->[1]{queryState},'scope is part of snapshot identity');
$db->begin;$db->dbh->do('UPDATE jemailqueries SET created=0');$db->commit;
is($api->api_Email_queryChanges(args(sinceQueryState=>$indexed->[1]{queryState}))->[1]{type},'cannotCalculateChanges','expired snapshot is not advertised as a precise diff');
{
  local $ENV{JMAP_QUERY_MAX_ROWS}=3;
  my $large=$api->api_Email_query(args(filter=>{inMailboxOtherThan=>[]},limit=>5,calculateTotal=>JSON::XS::true));
  is(scalar @{$large->[1]{ids}},5,'over-budget snapshot still returns the requested page');
  is($large->[1]{total},12,'over-budget snapshot retains correct total');
  ok(!$large->[1]{canCalculateChanges},'ephemeral over-budget result honestly disables changes');
}
{
  local $ENV{JMAP_QUERY_MAX_BYTES}=100;
  my $small=$api->api_Email_query(args(limit=>2));
  ok(!$small->[1]{canCalculateChanges},'lowered byte budget is enforced even for an existing query');
  $db->begin_read;
  my ($bytes)=$db->dbh->selectrow_array('SELECT COALESCE(SUM(bytes),0) FROM jemailqueries');
  $db->commit;
  cmp_ok($bytes,'<=',100,'lowered byte budget evicts oversized prior snapshots');
}
{
  local $ENV{JMAP_QUERY_MAX_ROWS}=50;local $ENV{JMAP_QUERY_MAX_SNAPSHOTS}=2;
  for my $n (1..7) {$api->api_Email_query(args(filter=>{minSize=>$n},limit=>1))}
  $db->begin_read;
  my ($snapshots,$rows)=$db->dbh->selectrow_array('SELECT COUNT(*),COALESCE(SUM(total),0) FROM jemailqueries');
  $db->commit;
  cmp_ok($snapshots,'<=',2,'persistent snapshot count stays bounded');
  cmp_ok($rows,'<=',50,'persistent snapshot row budget stays bounded');
}
$connection->{Callbacks}=undef;
$db->begin;
$db->ddirty('jmessages',{thrid=>'shared'},{msgid=>'m1'});
$db->ddirty('jmessages',{thrid=>'shared',keywords=>encode_json({'$seen'=>1})},{msgid=>'m2'});
$db->commit;
my $thread_filter={someInThreadHaveKeyword=>'$seen'};
my $thread_query=$api->api_Email_query(args(filter=>$thread_filter,collapseThreads=>JSON::XS::true));
$db->begin;$db->ddirty('jmessages',{keywords=>encode_json({'$seen'=>1})},{msgid=>'m1'});$db->commit;
my $thread_changes=$api->api_Email_queryChanges(args(filter=>$thread_filter,collapseThreads=>JSON::XS::true,sinceQueryState=>$thread_query->[1]{queryState}));
ok((grep {$_ eq 'm2'} @{$thread_changes->[1]{removed}}),'a changed sibling reinserts the unchanged representative for a thread-wide mutable query');
my $other=JMAP::ImapDB->new('other-account');
$other->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
my $other_api=JMAP::API->new($other);
is($other_api->api_Email_queryChanges({filter=>$thread_filter,sort=>[{property=>'receivedAt',isAscending=>JSON::XS::false}],
  collapseThreads=>JSON::XS::true,sinceQueryState=>$thread_query->[1]{queryState}})->[1]{type},'cannotCalculateChanges','another account cannot reuse a snapshot token');
$db->begin;$db->dbh->do('UPDATE account SET jdeletedmodseq=jhighestmodseq');$db->commit;
is($api->api_Email_queryChanges(args(filter=>$thread_filter,collapseThreads=>JSON::XS::true,
  sinceQueryState=>$thread_query->[1]{queryState}))->[1]{type},'cannotCalculateChanges','history purge floor invalidates an unsafe older mutable snapshot');
done_testing;
