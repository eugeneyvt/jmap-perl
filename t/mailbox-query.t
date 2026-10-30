use strict;
use warnings;
use Test::More;
use JSON::XS qw(encode_json);
BEGIN {
  require File::Temp;
  $ENV{JMAP_DATADIR} = File::Temp::tempdir(CLEANUP => 1);
  $ENV{JMAP_SECRET_KEY} = 'd' x 64;
}
use JMAP::ImapDB;
use JMAP::API;

{
  package GeneralQueryAPI;
  use parent 'JMAP::API';
  sub _mailbox_query_rows { undef }
}

my $db = JMAP::ImapDB->new('query');
$db->{change_cb} = sub {};
$db->setuser({username => 'test', password => 'synthetic', imapHost => 'example.invalid'});
$db->begin();
for my $row (
  ['m1','t1',100,1,1,{'$seen'=>1}],
  ['m2','t1',300,1,1,{}],
  ['m3','t2',200,1,1,{'$flagged'=>1}],
  ['m4','t3',300,1,1,{'$seen'=>1}],
  ['m5','t4',400,1,0,{}],
  ['m6','t5',500,0,1,{}],
  ['m7','t6',600,1,0,{}],
  ['m8','t2',200,1,0,{}],
  ['m9','t9',undef,1,1,{}],
) {
  my ($id,$thread,$date,$active,$inbox,$keywords) = @$row;
  $db->dmake('jmessages',{msgid=>$id,thrid=>$thread,internaldate=>$date,active=>$active,
    keywords=>encode_json($keywords),isUnread=>$keywords->{'$seen'} ? 0 : 1,
    sortsubject=>'subject '.$id,msgsize=>10});
  $db->dmake('jmessagemap',{msgid=>$id,jmailboxid=>'inbox',active=>$inbox});
  $db->dmake('jmessagemap',{msgid=>$id,jmailboxid=>'other',active=>1});
  # dmake activates newly created records. Model deleted messages/memberships
  # explicitly after creation rather than relying on an overridden input flag.
  $db->ddirty('jmessages',{active=>0},{msgid=>$id}) unless $active;
  $db->ddirty('jmessagemap',{active=>0},{msgid=>$id,jmailboxid=>'inbox'}) unless $inbox;
}
$db->commit();
my $api = JMAP::API->new($db);
my $general = GeneralQueryAPI->new($db);

sub args {
  return {accountId=>'query',filter=>{inMailbox=>'inbox'},
    sort=>[{property=>'receivedAt',isAscending=>JSON::XS::false}],
    collapseThreads=>JSON::XS::true,@_};
}
sub response {
  my ($client,$params)=@_;
  my @reply=$client->api_Email_query($params);
  return $reply[0];
}

my @cases=(
  ['newest first',args(),['m2','m4','m3','m9'],0,4],
  ['copies uncollapsed',args(collapseThreads=>JSON::XS::false),['m2','m4','m3','m1','m9'],0,5],
  ['oldest first',args(sort=>[{property=>'receivedAt'}]),['m9','m1','m3','m4'],0,4],
  ['page',args(position=>1,limit=>2),['m4','m3'],1,4],
  ['last page',args(position=>-2,limit=>2),['m3','m9'],2,4],
  ['anchor ignores position',args(anchor=>'m3',anchorOffset=>-1,position=>99,limit=>2),['m4','m3'],1,4],
  ['unread',args(filter=>{operator=>'AND',conditions=>[{inMailbox=>'inbox'},{notKeyword=>'$seen'}]}),['m2','m3','m9'],0,3],
  ['keyword',args(filter=>{inMailbox=>'inbox',hasKeyword=>'$flagged'}),['m3'],0,1],
  ['missing folder',args(filter=>{inMailbox=>'missing'}),[],0,0],
  ['bound folder ID',args(filter=>{inMailbox=>"inbox' OR 1=1 --"}),[],0,0],
);
for my $case (@cases) {
  my ($label,$params,$ids,$position,$total)=@$case;
  my $reply=response($api,$params);
  is($reply->[0],'Email/query',"$label returns a query");
  is_deeply($reply->[1]{ids},$ids,"$label returns the expected IDs and order");
  is($reply->[1]{position},$position,"$label position");
  is($reply->[1]{total},$total,"$label total");
  is_deeply($reply,response($general,$params),"$label matches the general query response");
}

$api->setid('folder','inbox');
is_deeply(response($api,args(filter=>{inMailbox=>'#folder'}))->[1]{ids},
  ['m2','m4','m3','m9'],'creation ID references are resolved');
is(response($api,args(anchor=>'absent'))->[1]{type},'anchorNotFound','missing anchor is refused');

# The query cache is a full ordered result, even if the caller requested one row.
my $paged=response($api,args(limit=>1));
my $cached=$db->load_query('Email',{
  filter=>{inMailbox=>'inbox'},sort=>[{property=>'receivedAt',isAscending=>JSON::XS::false}],
  collapseThreads=>1},$paged->[1]{queryState});
is_deeply($cached,['m2','m4','m3','m9'],'query state retains the full result for queryChanges');
my $changes=$api->api_Email_queryChanges(args(sinceQueryState=>$paged->[1]{queryState}));
is_deeply($changes->[1]{removed},[],'unchanged query removes nothing');
is_deeply($changes->[1]{added},[],'unchanged query adds nothing');
is($changes->[1]{total},4,'queryChanges agrees on the collapsed total');

# Thread predicates consider the whole conversation, including other folders;
# the optimized mailbox route must not narrow their universe.
for my $params (
  args(filter=>{operator=>'AND',conditions=>[{inMailbox=>'inbox'},{someInThreadHaveKeyword=>'$seen'}]}),
  args(filter=>{operator=>'OR',conditions=>[{inMailbox=>'inbox'},{inMailbox=>'other'}]}),
  args(sort=>[{property=>'subject',isAscending=>JSON::XS::false}]),
  args(sort=>[{property=>'receivedAt'},{property=>'id'}]),
) {
  is_deeply(response($api,$params),response($general,$params),'general filters/sorts retain their original behavior');
}
done_testing();
