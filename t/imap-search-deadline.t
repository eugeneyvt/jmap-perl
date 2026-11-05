use strict;
use warnings;
use Test::More;
use IO::Socket::INET;
use Time::HiRes qw(time sleep alarm);
use POSIX qw(WNOHANG);
use JMAP::Sync::Common;
{
 package BlockingSearch;
 use parent 'JMAP::Sync::Common';
 sub _imap_ssl {0}
 sub _imap_extra {(UseBlocking=>1)}
}
sub exercise {
 my ($persistent)=@_;
 my $listen=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>0,Listen=>4,ReuseAddr=>1,Proto=>'tcp') or die $!;
 my $port=$listen->sockport;
 my $pid=fork();die $! unless defined $pid;
 if(!$pid) {
  $SIG{ALRM}='DEFAULT';CORE::alarm(8);
  my $connection=0;
  while(my $s=$listen->accept) {
   $connection++;$s->autoflush(1);
   print $s "* OK [CAPABILITY IMAP4rev1 UNSELECT] synthetic\r\n";
   while(my $line=<$s>) {
    my ($tag,$command)=$line=~/^(\S+)\s+(.*)/;next unless $tag;
    if($command=~/^CAPABILITY/i){print $s "* CAPABILITY IMAP4rev1 UNSELECT\r\n"}
    elsif($command=~/^EXAMINE/i){print $s "* 1 EXISTS\r\n* OK [UIDVALIDITY 7]\r\n* OK [UIDNEXT 10]\r\n"}
    elsif($command=~/^(?:UID )?SEARCH/i) {
     if($persistent || $connection==1){$s->sysread(my $discard,1);last}
     print $s "* SEARCH 9\r\n";
    }
    print $s "$tag OK completed\r\n";
   }
   close $s;
  }
  exit 0;
 }
 close $listen;
 my $transport=bless {auth=>{imapHost=>'127.0.0.1',imapPort=>$port,username=>'synthetic',password=>'synthetic'},search_attempt_seconds=>.2},'BlockingSearch';
 my $start=time;my $result=eval {$transport->imap_search('INBOX','text','needle')};my $error=$@;
 undef $transport;kill 'TERM',$pid;waitpid($pid,0);
 return ($result,$error,time-$start);
}
my ($r,$e,$elapsed)=exercise(0);
is($e,'','an actual blocked socket is interrupted and reconnected');
is_deeply($r,['search','INBOX',7,[9]],'only the fresh connection supplies results');
cmp_ok($elapsed,'<',2,'recovery occurs before the outer HTTP deadline');
($r,$e,$elapsed)=exercise(1);
ok(!$r,'persistent blocking is never reported as empty success');
like($e,qr/Provider search attempt timed out/,'persistent timeout retains its cause');
cmp_ok($elapsed,'<',2,'only two bounded attempts are made');
is(alarm(0),0,'no search timer leaks after failure');
{
 my $transport=bless {search_attempt_seconds=>.5},'JMAP::Sync::Common';
 my $handler=sub {die "original outer deadline\n"};local $SIG{ALRM}=$handler;
 alarm(.05);eval {$transport->_bounded_search_attempt(sub {sleep .2})};
 like($@,qr/original outer deadline/,'an earlier outer deadline remains authoritative');
 is($SIG{ALRM},$handler,'original alarm handler is restored');
 is(alarm(0),0,'expired outer deadline is not rearmed');
 alarm(1);is($transport->_bounded_search_attempt(sub {sleep .02;'result'}),'result','successful bounded result is retained');
 my $remaining=alarm(0);
 cmp_ok($remaining,'>',.8,'later outer deadline remains scheduled');
 cmp_ok($remaining,'<',1,'time spent in search is deducted from outer deadline');
}
done_testing;
