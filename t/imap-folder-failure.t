use strict;
use warnings;
use Test::More;
BEGIN {
  require File::Temp;
  $ENV{JMAP_DATADIR} = File::Temp::tempdir(CLEANUP => 1);
  $ENV{JMAP_SECRET_KEY} = 'c' x 64;
}
use JMAP::ImapDB;
use JMAP::Sync::Common;

{
  package FolderReplyImap;
  sub namespace { $_[0]{namespace} }
  sub capability { $_[0]{capabilities} || {} }
  sub list { @{$_[0]{rows}} }
  sub xlist { @{$_[0]{rows}} }
  sub get_last_error { $_[0]{error} }
  sub logout { 1 }
  package FolderReplyTransport;
  use parent 'JMAP::Sync::Common';
  sub connect_imap { $_[0]{imap} }
  package FolderSnapshotDB;
  use parent 'JMAP::ImapDB';
  sub backend_cmd {
    my ($self, $cmd, $names) = @_;
    return $self->{transport}->folders() if $cmd eq 'folders';
    return {map { $_ => {uidvalidity => 7, uidnext => 42} } @$names}
      if $cmd eq 'imap_status';
    return {} if $cmd eq 'imap_getuniqueid' || $cmd eq 'imap_myrights';
    die "Unexpected backend command: $cmd";
  }
}

my $imap = bless {
  namespace => [[['', '/']]],
  rows => [[[], '/', 'INBOX'], [[], '/', 'Sent']],
}, 'FolderReplyImap';
my $transport = bless {imap => $imap}, 'FolderReplyTransport';
my $db = FolderSnapshotDB->new('folder-failure');
$db->{transport} = $transport;
$db->setuser({username => 'test', password => 'synthetic', imapHost => 'example.invalid'});
$db->sync_folders();

sub snapshot {
  $db->begin();
  my $folders = $db->dget('ifolders');
  my $mailboxes = $db->dget('jmailboxes', {active => 1});
  $db->commit();
  return {folders => $folders, mailboxes => $mailboxes};
}
my $before = snapshot();
is(scalar @{$before->{mailboxes}}, 2, 'seeded Inbox and Sent');

for my $case (
  ['connection closed', [undef], 'connection closed'],
  ['tagged failure with partial rows', [[[], '/', 'INBOX']], 'NO unavailable'],
  ['malformed reply without error', [undef], undef],
  ['empty reply without error', [], undef],
  ['malformed folder row', [[[], '/', undef]], undef],
) {
  my ($label, $rows, $error) = @$case;
  $imap->{rows} = $rows;
  $imap->{error} = $error;
  my $ok = eval { $db->sync_folders(); 1 };
  ok(!$ok, "$label is rejected");
  like($@, qr/cached folders preserved/, "$label reports a failed snapshot");
  is_deeply(snapshot(), $before, "$label preserves folders, IDs, counts and checkpoints");
}

$imap->{namespace} = undef;
my $ok = eval { $db->sync_folders(); 1 };
ok(!$ok, 'failed NAMESPACE is rejected');
is_deeply(snapshot(), $before, 'failed NAMESPACE preserves the snapshot');

$imap->{namespace} = [[['', '/']]];
$imap->{rows} = [[[], '/', 'INBOX'], [[], '/', 'Sent'], [[], '/', 'Archive']];
$imap->{capabilities} = {xlist => 1};
$imap->{error} = undef;
$db->sync_folders();
my $recovered = snapshot();
is(scalar @{$recovered->{mailboxes}}, 3, 'next successful XLIST adds the new folder');
my %ids = map { $_->{name} => $_->{jmailboxid} } @{$recovered->{mailboxes}};
for my $mailbox (@{$before->{mailboxes}}) {
  is($ids{$mailbox->{name}}, $mailbox->{jmailboxid}, 'successful retry keeps the existing mailbox ID');
}

# A successful nonempty snapshot may still remove a genuinely deleted folder.
$imap->{rows} = [[[], '/', 'INBOX'], [[], '/', 'Archive']];
$db->sync_folders();
is_deeply([sort map { $_->{name} } @{snapshot()->{mailboxes}}], ['Archive', 'INBOX'],
  'a successful listing still reconciles a genuinely removed folder');
done_testing();
