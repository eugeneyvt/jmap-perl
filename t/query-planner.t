use strict;
use warnings;
use utf8;
use Test::More;
use JSON::XS qw(encode_json decode_json);
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='a'x64}
use JMAP::ImapDB;
use JMAP::API;
{
  package ReferenceQueryAPI;
  use parent 'JMAP::API';
  sub _email_query_plan {undef}
  sub _mailbox_query_rows {undef}
}
my $db=JMAP::ImapDB->new('planner');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
$db->begin;
for my $i (1..47) {
  my $id=sprintf('m%03d',$i);
  my $keywords= $i%4==0 ? {'$seen'=>1,'x.key"quote'=>1} : $i%3==0 ? {'$flagged'=>1} : {};
  $db->dmake('jmessages',{msgid=>$id,thrid=>$i%13==0 ? undef : 't'.int($i/3),
    internaldate=>$i%9==0 ? undef : ($i%8)*100,msgdate=>($i%5)*100,msgsize=>$i*11,
    keywords=>encode_json($keywords),sortsubject=>Encode::encode_utf8($i%2 ? 'ёж' : 'Äpfel'),
    msgfrom=>$i%2 ? 'A@example.invalid' : 'b@example.invalid',msgto=>'recipient',isUnread=>$keywords->{'$seen'} ? 0 : 1});
  $db->dmake('jmessagemap',{msgid=>$id,jmailboxid=>$i%2 ? 'inbox' : 'other'});
  $db->dmake('jmessagemap',{msgid=>$id,jmailboxid=>'both'}) if $i%5==0;
  $db->dinsert('jrawmessage',{msgid=>$id,hasAttachment=>1}) if $i%7==0;
  $db->ddirty('jmessages',{active=>0},{msgid=>$id}) if $i%11==0;
  $db->ddirty('jmessagemap',{active=>0},{msgid=>$id,jmailboxid=>'inbox'}) if $i%17==0;
}
$db->commit;
my $api=JMAP::API->new($db);my $reference=ReferenceQueryAPI->new($db);
my @filters=(undef,{}, {inMailbox=>'inbox'}, {inMailbox=>'absent'},
  {inMailboxOtherThan=>['inbox','both']},{inMailboxOtherThan=>[]},
  {hasKeyword=>'x.key"quote'},{notKeyword=>'$seen'},{hasAttachment=>JSON::XS::true},{hasAttachment=>JSON::XS::false},
  {before=>'1970-01-01T00:05:00Z',after=>'1970-01-01T00:01:40Z'}, {minSize=>200,maxSize=>400},
  {allInThreadHaveKeyword=>'$seen'},{someInThreadHaveKeyword=>'$flagged'},{noneInThreadHaveKeyword=>'$seen'},
  {operator=>'OR',conditions=>[{inMailbox=>'inbox'},{hasAttachment=>JSON::XS::true}]},
  {operator=>'NOT',conditions=>[{hasKeyword=>'$seen'},{inMailbox=>'other'}]},
  {operator=>'AND',conditions=>[{inMailbox=>'inbox'},{someInThreadHaveKeyword=>'$seen'}]},
  {operator=>'AND',conditions=>[]},{operator=>'OR',conditions=>[]},{operator=>'NOT',conditions=>[]});
my @sorts=([{property=>'receivedAt',isAscending=>JSON::XS::false}],[{property=>'receivedAt'}],
  [{property=>'sentAt'},{property=>'size',isAscending=>JSON::XS::false}],
  [{property=>'subject',collation=>'i;unicode-casemap'}],[{property=>'from',collation=>'i;octet'}],
  [{property=>'to',collation=>'i;ascii-casemap'}],[{property=>'hasKeyword',keyword=>'$seen'}],
  [{property=>'allInThreadHaveKeyword',keyword=>'$seen'}],[{property=>'someInThreadHaveKeyword',keyword=>'$flagged'}],[]);
for my $i (0..209) {
  my $args={accountId=>'planner',filter=>$filters[$i%@filters],sort=>$sorts[int($i/@filters)%@sorts],
    collapseThreads=>$i%2 ? JSON::XS::true : JSON::XS::false,calculateTotal=>JSON::XS::true,
    position=>($i%5)-2,limit=>$i%8};
  my $new=$api->api_Email_query($args);
  my $old;
  {local $SIG{__WARN__}=sub {warn $_[0] unless $_[0]=~/uninitialized value/};($old)=$reference->api_Email_query($args)}
  is($new->[0],'Email/query',"case $i succeeds through SQL");
  $new->[1]{queryState}=$old->[1]{queryState};
  is_deeply($new,$old,"case $i matches independent Perl ordering/filter/collapse/page semantics");
}
my $empty=$api->api_Email_query({accountId=>'planner',sort=>$sorts[0],limit=>0});
is_deeply($empty->[1]{ids},[],'zero limit returns no IDs');
ok(!exists $empty->[1]{total},'total omitted unless requested');
my $all=$api->api_Email_query({accountId=>'planner',sort=>$sorts[0],collapseThreads=>JSON::XS::true});
my $anchor=$all->[1]{ids}[3];
my $page=$api->api_Email_query({accountId=>'planner',sort=>$sorts[0],collapseThreads=>JSON::XS::true,
  anchor=>$anchor,anchorOffset=>-1,position=>999,limit=>2});
is_deeply($page->[1]{ids},[@{$all->[1]{ids}}[2,3]],'anchor is resolved after thread collapse and ignores position');
is($api->api_Email_query({accountId=>'another',limit=>1})->[1]{type},'accountNotFound','SQL path checks account boundary');
done_testing;
