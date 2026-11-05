use strict;
use warnings;
use Test::More;
use JMAP::Sync::Common;

{
  package SearchFake;
  sub examine { 1 }
  sub get_response_code { 7 }
  sub capability { {unselect=>1,'search=fuzzy'=>1} }
  sub unselect { 1 }
  sub search {
    my ($s,@args)=@_; push @{$s->{seen}},\@args;
    my $next=shift @{$s->{replies}};
    die $next unless ref($next) eq 'ARRAY';
    return $next;
  }
  package SearchTransport;
  use parent 'JMAP::Sync::Common';
  sub connect_imap { push @{$_[0]{connections}}, $_[1]; $_[0]{imap} }
}
sub exercise {
  my (@replies)=@_;
  my $imap=bless {replies=>\@replies,seen=>[]},'SearchFake';
  my $transport=bless {imap=>$imap,connections=>[]},'SearchTransport';
  my $result=eval {$transport->imap_search('INBOX','text','example')};
  return ($result,$@,$transport,$imap);
}
my ($r,$e,$t,$i)=exercise("IMAPTalk: IMAP Connection closed by other end: reset\n",[2,7]);
is($e,'','closed socket search recovers');
is_deeply($r,['search','INBOX',7,[2,7]],'only recovered search results are returned');
is_deeply($t->{connections},[0,1],'second attempt explicitly requests a new connection');
is_deeply($i->{seen}[0],$i->{seen}[1],'fuzzy wrapping does not accumulate on retry');
($r,$e,$t)=exercise("IMAPTalk: Read timed out on socket\n",[]);
is($e,'','one transient transport timeout can recover');
is_deeply($r,['search','INBOX',7,[]],'valid empty search remains a success');
($r,$e,$t)=exercise("IMAPTalk: Read timed out on socket\n","IMAPTalk: Read timed out on socket\n",[9]);
ok(!$r,'persistent failure is not empty success');
like($e,qr/Read timed out/,'persistent transport error is retained');
is(scalar @{$t->{connections}},2,'transport retry is bounded');
($r,$e,$t)=exercise("NO [UNAVAILABLE] failed\n",[3]);
like($e,qr/UNAVAILABLE/,'provider refusal remains visible');
is(scalar @{$t->{connections}},1,'provider refusal does not trigger a hidden retry');
done_testing;
