use Test::More;
use strict;
use warnings;
use JSON::XS;
use JMAP::API;
use JMAP::Sync::Common;
use JMAP::ImapDB;

{
  package FlagImap;
  sub select { 1 }
  sub capability { {'x-gm-ext-1' => 1, unselect => 1} }
  sub get_response_code { $_[0]{validity} // 7 }
  sub store {
    my ($self,$uid,$operation,$flag)=@_;
    push @{$self->{stores}}, [$uid,$operation,$flag];
    $self->{seen} = $operation =~ /^\+/ ? 1 : 0;
    return 1;
  }
  sub fetch { my $s=shift; return {42=>{flags=>[$s->{seen} ? '\\Seen' : (), '\\Flagged','custom'], 'x-gm-labels'=>['Inbox']}} }
  sub unselect { 1 }
  sub logout { 1 }
  package FlagTransport;
  use parent 'JMAP::Sync::Common';
  sub connect_imap { $_[0]{imap} }
}
my $imap=bless {seen=>1},'FlagImap';
my $transport=bless {imap=>$imap},'FlagTransport';
my $data=$transport->imap_patch_flags('test',7,[42],{'$seen'=>JSON::XS::true});
die 'Patch replaced unrelated flags' unless join(',',@{$data->{42}{flags}}) eq '\\Seen,\\Flagged,custom';
die 'Patch did not use additive STORE' unless $imap->{stores}[0][1] eq '+flags.silent';
$transport->imap_patch_flags('test',7,[42],{'$seen'=>undef});
die 'Removal replaced all flags' unless $imap->{stores}[1][1] eq '-flags.silent';
$imap->{validity}=8;
my $before=@{$imap->{stores}};
eval {$transport->imap_patch_flags('test',7,[42],{'$seen'=>JSON::XS::true})};
die 'UIDVALIDITY mismatch was accepted' unless $@ && @{$imap->{stores}}==$before;

{
  package PatchDB;
  sub accountid { 'test-account' }
  sub begin_superlock { bless {}, 'HeldLock' }
  sub get_user { {jstateEmail=>$_[0]{state} // 1} }
  sub sync_imap { $_[0]{full_sync}++; }
  sub create_messages { ({},{}) }
  sub destroy_messages { ([],{}) }
  sub update_keyword_patches { $_[0]{targeted}++; $_[0]{state}=2; return ({map {$_=>undef} keys %{$_[1]}},{}) }
  sub update_messages { $_[0]{ordinary}++; return ({},{}) }
  package PatchAPI;
  use parent 'JMAP::API';
  sub begin { }
  sub commit { }
  sub idmap { $_[1] }
  sub _transError { $_[1] }
  sub _resolve_patch { }
}
my $db=bless {},'PatchDB';my $api=bless {db=>$db},'PatchAPI';
my @result=$api->api_Email_set({accountId=>'test-account',update=>{message=>{'keywords/$seen'=>JSON::XS::true}}});
die 'A flag patch performed a full mailbox sync' if $db->{full_sync};
die 'A flag patch did not use targeted readback' unless $db->{targeted}==1 && exists($result[0][1]{updated}{message});
my $writes=$db->{targeted};
my @stale=$api->api_Email_set({ifInState=>'stale',update=>{message=>{'keywords/$seen'=>JSON::XS::true}}});
die 'State mismatch allowed a mutation' unless $stale[0][1]{type} eq 'stateMismatch' && $db->{targeted}==$writes;
$api->api_Email_set({update=>{message=>{'mailboxIds/folder'=>JSON::XS::true}}});
die 'A mailbox move incorrectly used the flag shortcut' unless $db->{ordinary} && $db->{targeted}==$writes && $db->{full_sync}==2;
print encode_json({targeted_flag_patch=>JSON::XS::true,unrelated_flags_preserved=>JSON::XS::true,uidvalidity_checked=>JSON::XS::true,state_mismatch_prevents_write=>JSON::XS::true,other_mutations_keep_original_path=>JSON::XS::true})."\n";
$ENV{JMAP_SUITE_FLAG_COMPAT}=1;
my $false_patch={'keywords/$seen'=>JSON::XS::false};
my $syncs=$db->{full_sync};
$api->api_Email_set({update=>{message=>$false_patch}});
die 'Suite false was not normalized to JMAP removal' if defined($false_patch->{'keywords/$seen'});
die 'Removing a flag performed a full sync' unless $db->{full_sync}==$syncs && $db->{targeted}==$writes+1;
print "Suite false-to-null patch compatibility passed.\n";

pass("Compatibility assertions completed");
done_testing();
