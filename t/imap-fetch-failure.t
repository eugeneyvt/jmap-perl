use strict;
use warnings;
use Test::More;
use JMAP::Sync::Common;

{
  package FetchReplyImap;
  sub examine { 1 }
  sub get_response_code { +{uidvalidity=>7,uidnext=>11,highestmodseq=>0,exists=>10}->{$_[1]} }
  sub capability { {unselect=>1} }
  sub unselect { $_[0]{unselected}++; 1 }
  sub fetch { my $s=shift; $s->{calls}++; return shift @{$s->{replies}} }
  sub logout { 1 }
  package FetchReplyTransport;
  use parent 'JMAP::Sync::Common';
  sub connect_imap { $_[0]{imap} }
}

sub request {
  my (@replies)=@_;
  my $imap=bless {replies=>\@replies},'FetchReplyImap';
  my $transport=bless {imap=>$imap},'FetchReplyTransport';
  my $result=eval { $transport->imap_fetch('INBOX',{uidvalidity=>7},{backfill=>[1,10,1]}) };
  return ($result,$@,$imap);
}

my ($r,$error,$imap)=request(undef, '[UNAVAILABLE] uid fetch message failure', {5=>{uid=>5}});
is($error,'','temporary FETCH failures recover');
is_deeply($r->{backfill}[1],{5=>{uid=>5}},'successful data retained after retry');
is($imap->{calls},3,'read retries are bounded');
is($imap->{unselected},1,'successful read leaves selected state');

($r,$error,$imap)=request(undef,undef,undef);
ok(!$r,'persistent failure is not an empty successful range');
like($error,qr/checkpoint preserved/,'failure stops before the caller can advance its checkpoint');
is($imap->{calls},3,'persistent failure stops after three attempts');

($r,$error,$imap)=request({});
is($error,'','valid empty FETCH succeeds');
is_deeply($r->{backfill}[1],{},'a genuine empty range remains valid');
is($imap->{calls},1,'valid empty result is not retried');
done_testing;
