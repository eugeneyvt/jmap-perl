use strict;
use warnings;
use Test::More;
use JSON::XS qw(encode_json decode_json);
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='a'x64}
use JMAP::GmailDB;
my $db=JMAP::GmailDB->new('selected-label');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
$db->begin;
for my $row ([1=>'Inbox','\\Inbox','inbox'],[2=>'All Mail','\\AllMail','archive'],[3=>'Project','Project','project']) {
 $db->dinsert('ifolders',{ifolderid=>$row->[0],imapname=>$row->[1],label=>$row->[2],jmailboxid=>$row->[3],sep=>'/'});
 $db->dmake('jmailboxes',{jmailboxid=>$row->[3],name=>$row->[1],role=>$row->[3] eq 'project' ? undef : $row->[3]});
}
$db->dmake('jmessages',{msgid=>'m',thrid=>'thread',keywords=>'{}'});
$db->dmake('jmessagemap',{msgid=>'m',jmailboxid=>'inbox'});
for my $f ([1,11],[2,91]) {
 $db->dbh->do('INSERT INTO imessages(ifolderid,uid,msgid,flags,labels,mtime) VALUES(?,?,?,?,?,?)',{},@$f,'m','[]',encode_json(['\\Inbox']),10);
}
$db->commit;
# Real provider response: a UID remains in a freshly selected Inbox while
# X-GM-LABELS is empty. Its All Mail copy names Inbox explicitly.
my @selected=$db->calclabels('\\Inbox',{'x-gm-labels'=>[]});
is_deeply(\@selected,['\\Inbox'],'fresh selected Inbox survives an omitted implicit label');
$db->begin;
$db->changed_record(1,11,['\\Seen'],\@selected);
$db->dbh->do('UPDATE imessages SET mtime=20 WHERE ifolderid=1');
$db->sync_jmap_msgid('m');
my $members=sub {$db->dbh->selectcol_arrayref("SELECT jmailboxid FROM jmessagemap WHERE msgid='m' AND active=1 ORDER BY jmailboxid")};
is_deeply($members->(),['inbox'],'marking read does not archive the message');
ok(decode_json($db->dgetone('jmessages',{msgid=>'m'})->{keywords})->{'$seen'},'Seen is applied');
$db->commit;
is_deeply([$db->calclabels('Project',{'x-gm-labels'=>['\\Inbox']})],['\\Inbox','Project'],'selected custom label coexists with explicit labels');
is_deeply([$db->calclabels('\\Inbox',{'x-gm-labels'=>['\\Inbox']})],['\\Inbox'],'implicit label is deduplicated');
is_deeply([$db->calclabels('\\AllMail',{'x-gm-labels'=>[]})],[],'All Mail adds no implicit archive label');
# A newer authoritative All Mail removal must still beat stale Inbox data.
my @removed=$db->calclabels(undef,{'x-gm-labels'=>[]});
$db->begin;
$db->changed_record(2,91,['\\Seen'],\@removed);
$db->dbh->do('UPDATE imessages SET mtime=30 WHERE ifolderid=2');
$db->sync_jmap_msgid('m');
is_deeply($members->(),['archive'],'a later archive is not resurrected from stale Inbox data');
$db->commit;
done_testing;
