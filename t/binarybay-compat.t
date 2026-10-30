use Test::More;
BEGIN { $ENV{JMAP_SECRET_KEY} = 'a' x 64; }
use strict;
use warnings;
use JMAP::Sync::Gmail;
use JMAP::CredentialStore;

my $password = 'synthetic-test-credential';
my $encrypted = JMAP::CredentialStore->encrypt($password);
die 'Credential encryption was bypassed' if $encrypted eq $password;
die 'Credential round trip failed' unless JMAP::CredentialStore->decrypt($encrypted) eq $password;

$ENV{JMAP_GMAIL_APP_PASSWORD} = 1;
my $backend = bless {auth => {username => 'test@example.invalid', password => $password,
    smtpHost => 'smtp.gmail.com', smtpPort => 587, smtpSSL => 3}}, 'JMAP::Sync::Gmail';
die 'App-password transport still requires OAuth' unless $backend->_imap_class() eq 'Mail::IMAPTalk';
my @auth = $backend->_imap_auth();
die 'Incorrect app-password IMAP authentication' unless $auth[0] eq 'Password' && $auth[1] eq $password;
my $smtp = $backend->_smtp_transport('suite-test.invalid');
die 'SMTP encryption mismatch' unless $smtp->ssl() eq 'starttls';
delete $ENV{JMAP_GMAIL_APP_PASSWORD};
die 'Default OAuth path changed' unless $backend->_imap_class() eq 'Mail::GmailTalk';
{
    package MockImap;
    sub namespace { [ [ ['', '/'] ] ] }
    sub capability { {} }
    sub get_last_error { undef }
    sub list { ([['\\Noselect'],'/','[Gmail]'], [[], '/', 'INBOX']) }
    package MockFolders;
    use parent 'JMAP::Sync::Common';
    sub connect_imap { bless {}, 'MockImap' }
}
my $folders=bless({},'MockFolders')->folders();
die 'Unselectable container was treated as a mailbox' unless scalar(keys %{$folders->[1]})==1 && exists $folders->[1]{INBOX};
print "Credential encryption, app-password transport, STARTTLS, OAuth and unselectable-folder checks passed.\n";

pass("Compatibility assertions completed");
done_testing();
