use strict;
use warnings;
use Test::More;
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='c'x64}
use JMAP::ImapDB;
use JMAP::Sync::Gmail;
{
  package ImportFixtureDB;
  use parent 'JMAP::ImapDB';
  sub backend_cmd {
    my ($self,$cmd,@args)=@_;
    die 'network inside transaction' if $self->in_transaction;
    push @{$self->{calls}},[$cmd,@args];
    if ($cmd eq 'imap_append') {
      my $validity=$args[0] eq 'All Mail' ? 11 : 22;
      my $uid=++$self->{next_uid};$self->{appended}=[$args[0],$validity,$uid];
      return ['append',$args[0],$self->{bad_validity}?99:$validity,$uid];
    }
    return {updated=>$args[2]} if $cmd eq 'imap_add_labels';
    die 'unexpected backend method';
  }
  sub do_folder {
    my ($self,$folder,$label)=@_;
    push @{$self->{synced}},$folder;
    my $uid=$self->{appended}[2];
    $self->begin;
    $self->dinsert('imessages',{ifolderid=>$folder,uid=>$uid,msgid=>"stable-$folder-$uid",thrid=>'thread',size=>123,flags=>'[]',labels=>'[]'});
    $self->commit;
  }
}
my $db=ImportFixtureDB->new('gmail-import');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'imap.gmail.com'});
$db->begin;
for my $row ([1,'All Mail','\\AllMail',11,undef,undef],[2,'Drafts','\\Drafts',22,'drafts','drafts'],[3,'Label','User label',33,'custom',undef]) {
  $db->dinsert('ifolders',{ifolderid=>$row->[0],imapname=>$row->[1],label=>$row->[2],uidvalidity=>$row->[3],jmailboxid=>$row->[4],sep=>'/'});
  $db->dmake('jmailboxes',{jmailboxid=>$row->[4],role=>$row->[5],name=>$row->[1]}) if $row->[4];
}
$db->dmake('jmailboxes',{jmailboxid=>'archive',role=>'archive',name=>'Archive'});$db->commit;
my $raw="From: Test <sender\@example.invalid>\r\nSubject: draft\r\n\r\nbody\r\n";
my ($id)=$db->import_message($raw,['drafts'],{'$draft'=>1},1700000000);
is($db->{appended}[0],'Drafts','draft APPEND uses Drafts');
is($db->{synced}[-1],2,'APPENDUID is resolved in Drafts, not in unrelated All Mail UID space');
is($id,'stable-2-1','returned JMAP message identity matches the actual appended destination');
($id)=$db->import_message($raw,['archive'],{},1700000000);
is($db->{appended}[0],'All Mail','virtual Archive imports to the physical All Mail source');
is($id,'stable-1-2','Archive APPENDUID resolves in its actual source folder');
$db->import_message($raw,['drafts','custom'],{'$draft'=>1},1700000000);
my ($extra)=grep {$_->[0] eq 'imap_add_labels'} @{$db->{calls}};
is_deeply($extra, ['imap_add_labels','Drafts',22,3,['User label']],'additional Gmail mailbox labels are added without copying the MIME again');
my $before=scalar @{$db->{calls}};
eval {$db->import_message($raw,['drafts','unknown'],{},1700000000)};
like($@,qr/Unknown import mailbox/,'unknown destination is rejected before APPEND');
is(scalar @{$db->{calls}},$before,'invalid import performs no provider write');
$db->{bad_validity}=1;$before=scalar @{$db->{calls}};
eval {$db->import_message($raw,['drafts'],{},1700000000)};
like($@,qr/requires reconciliation/,'unexpected APPENDUID validity is explicit uncertain import outcome');
is(scalar(@{$db->{calls}})-$before,1,'uncertain APPEND is never replayed');

{
  package LabelFixtureIMAP;
  sub select {1}
  sub get_response_code {5}
  sub capability { {unselect=>1} }
  sub unselect {1}
  sub release_socket {undef}
  sub store {my ($self,@args)=@_;push @{$self->{writes}},\@args;return !$self->{fail}}
  sub fetch {my ($self,$uid)=@_;return {$uid=>{'x-gm-labels'=>['User label','quote"label'],flags=>[]}}}
  package LabelFixtureTransport;
  use parent 'JMAP::Sync::Gmail';
  sub connect_imap {$_[0]{imap}}
}
my $imap=bless {},'LabelFixtureIMAP';
my $transport=bless {imap=>$imap},'LabelFixtureTransport';
$transport->imap_labels('INBOX',5,7,['User label','quote"label']);
is_deeply($imap->{writes}[0],[7,'x-gm-labels',['User label','quote"label']],'label names go through native IMAP list quoting');
$transport->imap_add_labels('INBOX',5,7,['User label']);
is($imap->{writes}[1][1],'+x-gm-labels','additional import labels use an additive update');
$imap->{fail}=1;eval {$transport->imap_labels('INBOX',5,7,['User label'])};
like($@,qr/not confirmed/,'failed label STORE is not reported as success');
done_testing;
