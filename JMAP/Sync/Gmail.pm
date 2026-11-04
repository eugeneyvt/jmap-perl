#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Gmail;
use base qw(JMAP::Sync::Common);

use Sys::Hostname;
use Mail::GmailTalk;
use Email::Sender::Transport::GmailSMTP;
use OAuth2::Tiny;

my $O;
sub O {
  unless ($O) {
    my $client_id     = $ENV{GOOGLE_CLIENT_ID}
      or die "GOOGLE_CLIENT_ID environment variable not set\n";
    my $client_secret = $ENV{GOOGLE_CLIENT_SECRET}
      or die "GOOGLE_CLIENT_SECRET environment variable not set\n";
    my $redirect_uri  = $ENV{GOOGLE_REDIRECT_URI}
      || ($ENV{BASEURL} || 'http://localhost:9000') . '/cb/oauth';
    $O = OAuth2::Tiny->new(
      client_id     => $client_id,
      client_secret => $client_secret,
      auth_url      => 'https://accounts.google.com/o/oauth2/v2/auth',
      token_url     => 'https://oauth2.googleapis.com/token',
      callback_url  => $redirect_uri,
      scopes        => [
        'https://mail.google.com/',
        'https://www.googleapis.com/auth/calendar',
        'https://www.googleapis.com/auth/carddav',
        'email',
      ],
    );
  }
  return $O;
}

sub access_token {
  my $Self = shift;
  unless ($Self->{access_token}) {
    my $refresh_token = $Self->{auth}{password};
    my $O = $Self->O();
    my $data = $O->refresh($refresh_token);
    $Self->{access_token} = $data->{access_token};
  }
  return $Self->{access_token};
}

sub _imap_class { $ENV{JMAP_GMAIL_APP_PASSWORD} ? 'Mail::IMAPTalk' : 'Mail::GmailTalk' }
sub _imap_auth {
  my $Self = shift;
  return (Password => $Self->{auth}{password}) if $ENV{JMAP_GMAIL_APP_PASSWORD};
  return (Password => $Self->access_token());
}
sub _dav_auth   { my $Self = shift; (access_token => $Self->access_token()) }

sub _smtp_transport {
  my ($Self, $helo) = @_;
  if ($ENV{JMAP_GMAIL_APP_PASSWORD}) {
    require JMAP::Sync::Standard;
    return JMAP::Sync::Standard::_smtp_transport($Self, $helo);
  }
  Email::Sender::Transport::GmailSMTP->new({
    helo          => $helo,
    host          => $Self->{auth}{smtpHost},
    port          => $Self->{auth}{smtpPort},
    ssl           => 1,
    sasl_username => $Self->{auth}{username},
    access_token  => $Self->access_token(),
  });
}

sub imap_labels {shift->_write_labels('x-gm-labels',@_)}
sub imap_add_labels {shift->_write_labels('+x-gm-labels',@_)}

sub _write_labels {
  my $Self = shift;
  my $operation=shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;
  my $labels = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->select($imapname);
  die "SELECT FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    die "UIDVALIDITY changed before Gmail label write\n";
  }

  die "Invalid Gmail label list\n" unless ref($labels) eq 'ARRAY';
  # Pass native lists so IMAPTalk quotes spaces, quotes and backslashes; never
  # interpolate user folder names into an IMAP command string.
  $imap->store($uids,$operation,$labels) or die "Gmail label write not confirmed; do not retry automatically\n";
  my $readback=$imap->fetch($uids,'(uid flags x-gm-labels)');
  die "Gmail label readback unavailable\n" unless ref($readback) eq 'HASH' && keys(%$readback);
  die "Gmail label target disappeared\n" if $uids=~/^\d+$/ && !exists($readback->{$uids});
  die "Invalid Gmail label readback\n" if grep {ref($_->{'x-gm-labels'}) ne 'ARRAY'} values %$readback;
  $Self->_unselect($imap);

  $res{updated} = $uids;

  return \%res;
}

1;
