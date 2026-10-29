#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
BEGIN {
  require File::Temp;
  $ENV{JMAP_DATADIR} = File::Temp::tempdir(CLEANUP => 1);
  $ENV{JMAP_SECRET_KEY} = 'b' x 64;
}
use lib '.';
use JMAP::ImapDB;
use JMAP::API;
use JMAP::Sync::Common;

{
  package GenericFolderDB;
  use parent 'JMAP::ImapDB';
  sub backend_cmd {
    my ($self, $cmd, $names) = @_;
    if ($cmd eq 'folders') {
      my %folders;
      for my $name (qw(INBOX Sent Drafts Archive Outbox template Spam Trash)) {
        my $flag = $name eq 'INBOX' || $name eq 'Spam' ? '\\Marked' : '\\Unmarked';
        $folders{$name} = ['/', JMAP::Sync::Common::folder_label('', [[$flag], '/', $name])];
      }
      return ['', \%folders, '/'];
    }
    return {map { $_ => {uidvalidity => 1, uidnext => 1} } @$names} if $cmd eq 'imap_status';
    return {} if $cmd eq 'imap_getuniqueid' || $cmd eq 'imap_myrights';
    die "unexpected network operation: $cmd";
  }
}

my $db = GenericFolderDB->new('generic');
my %config = (username => 'local-login', password => 'synthetic-password',
  email => 'person@example.invalid', imapHost => 'imap.example.invalid');
$db->setuser(\%config);
$db->begin();
is($db->get_user->{email}, 'person@example.invalid', 'public email is independent of the IMAP login');
is($db->dgetone('iserver')->{username}, 'local-login', 'transport retains the local login');
$db->commit();

delete $config{email};
$db->setuser(\%config);
$db->begin();
is($db->get_user->{email}, 'person@example.invalid', 'settings update preserves the public email');
$db->commit();

# The second sync previously collapsed eight folders to just two status labels.
for my $pass (1..2) {
  $db->sync_folders();
  $db->begin();
  my $folders = $db->dget('ifolders');
  my $boxes = $db->dget('jmailboxes', {active => 1});
  is(scalar @$folders, 8, "sync $pass retains every IMAP folder");
  is(scalar @$boxes, 8, "sync $pass exposes every JMAP mailbox");
  my %roles = map { ($_->{role} // '') => $_->{name} } @$boxes;
  is($roles{inbox}, 'INBOX', "sync $pass identifies Inbox");
  is($roles{junk}, 'Spam', "sync $pass identifies Spam");
  $db->commit();
}

my $api = JMAP::API->new($db);
my $response = $api->api_Identity_get({accountId => 'generic'});
my $identity = $response->[1]{list}[0];
is($identity->{email}, 'person@example.invalid', 'sending identity uses the public email');
is_deeply($identity->{replyTo}, [{name => '', email => 'person@example.invalid'}],
  'default reply-to address includes a name for Suite consumers');
done_testing;
