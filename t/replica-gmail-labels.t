use strict;
use warnings;
use Test::More;
use JSON::XS qw(encode_json decode_json);
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='a'x64}
use JMAP::GmailDB;
my $db=JMAP::GmailDB->new('labels');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
is_deeply([$db->calclabels('Sent',{'x-gm-labels'=>['INBOX','Other']})],['INBOX','Other'],'Gmail source preserves full provider labels rather than forcing its selected folder');
is_deeply([$db->calclabels('Sent',{'x-gm-labels'=>[]})],[],'authoritative empty label set is preserved');
$db->begin;
for my $row ([1=>'INBOX','inbox'],[2=>'Other','other']) {
  $db->dinsert('ifolders',{ifolderid=>$row->[0],imapname=>$row->[1],label=>$row->[1],jmailboxid=>$row->[2],sep=>'/'});
  $db->dmake('jmailboxes',{jmailboxid=>$row->[2],name=>$row->[1]});
}
$db->dmake('jmessages',{msgid=>'provider-id',thrid=>'thread',keywords=>encode_json({'$seen'=>JSON::XS::true})});
$db->dmake('jmessagemap',{msgid=>'provider-id',jmailboxid=>'inbox'});
$db->dbh->do('INSERT INTO imessages(ifolderid,uid,msgid,flags,labels,mtime) VALUES(?,?,?,?,?,?)',{},1,1,'provider-id',encode_json(['\\Seen']),encode_json(['INBOX']),10);
$db->dbh->do('INSERT INTO imessages(ifolderid,uid,msgid,flags,labels,mtime) VALUES(?,?,?,?,?,?)',{},2,1,'provider-id','[]',encode_json(['Other']),20);
$db->sync_jmap_msgid('provider-id');
my $message=$db->dgetone('jmessages',{msgid=>'provider-id'});
is_deeply(decode_json($message->{keywords}),{},'older Seen flag is not resurrected from a stale label view');
my $members=$db->dbh->selectcol_arrayref("SELECT jmailboxid FROM jmessagemap WHERE msgid='provider-id' AND active=1 ORDER BY jmailboxid");
is_deeply($members,['other'],'removed Inbox label is not resurrected from a stale label view');
$db->commit;
$db->begin;
$db->dinsert('ifolders',{ifolderid=>3,imapname=>'Drafts',label=>'\\Drafts',jmailboxid=>'drafts',sep=>'/'});
$db->commit;
delete $db->{gmail_label_aliases};
is_deeply([$db->calclabels(undef,{'x-gm-labels'=>['\\Draft']})],['\\Drafts'],'Gmail Draft message label maps to the Drafts source identity');
done_testing;
