use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use HTTP::Tiny;
use JSON::XS qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use Time::HiRes qw(time sleep);
use Fcntl qw(:flock);
use POSIX qw(WNOHANG);
use JMAP::ImapDB;

my $dir=tempdir(CLEANUP=>1);
sub port {
  my $s=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>0,Listen=>1,Proto=>'tcp') or die $!;
  return $s->sockport;
}
my ($port,$mgmt)=(port(),port());
my $pid=fork();die $! unless defined $pid;
if (!$pid) {
  $ENV{JMAP_HOME}='.';$ENV{JMAP_DATADIR}=$dir;$ENV{JMAP_PORT}=$port;
  $ENV{JMAP_MGMT_PORT}=$mgmt;$ENV{JMAP_HOST}='127.0.0.1';$ENV{JMAP_MGMT_HOST}='127.0.0.1';
  $ENV{BASEURL}="http://127.0.0.1:$port";$ENV{JMAP_SECRET_KEY}='c' x 64;
  $ENV{JMAP_READ_DEADLINE}=2;$ENV{JMAP_IDLE_ENABLE}=0;$ENV{JMAP_SYNC_INTERVAL}=600;
  open STDOUT,'>',"$dir/proxy.log" or die $!;open STDERR,'>&',\*STDOUT or die $!;
  exec $^X,'-I.','bin/jmap-proxy.pl';die $!;
}
END {
  if ($pid) {
    kill 'TERM',$pid;
    my $end=time()+3;
    while(time()<$end) {last if waitpid($pid,WNOHANG)==$pid;sleep .05}
    if (kill(0,$pid)) {kill 'KILL',$pid;waitpid($pid,0)}
  }
}
my $http=HTTP::Tiny->new(timeout=>5,proxy=>undef,http_proxy=>undef,https_proxy=>undef);
my $alive;
for (1..60) {
  $alive=$http->get("http://127.0.0.1:$mgmt/healthz");last if $alive->{status}==200;
  sleep .1;
}
if (!$alive || $alive->{status}!=200) {
  open my $f,'<',"$dir/proxy.log";local $/;diag <$f>;
  BAIL_OUT('synthetic proxy failed to start');
}
is($alive->{status},200,'real parent responds to liveness');
is($http->get("http://127.0.0.1:$mgmt/readyz")->{status},503,'liveness does not imply account readiness');
my $created=$http->post("http://127.0.0.1:$mgmt/api/accounts",{
  headers=>{'Content-Type'=>'application/json'},content=>encode_json({accountid=>'synthetic',email=>'synthetic@example.invalid',type=>'imap'})});
is($created->{status},201,'synthetic account created without real provider');
local $JMAP::DB::DATADIR=$dir;
local $ENV{JMAP_SECRET_KEY}='c' x 64;
my $db=JMAP::ImapDB->new('synthetic');
$db->setuser({username=>'synthetic@example.invalid',password=>'synthetic-only',imapHost=>'127.0.0.1',imapPort=>1,imapSSL=>0});
my $auth=encode_base64('synthetic@example.invalid:synthetic-only','');
sub query {
  my ($calls)=@_;
  return $http->post("http://127.0.0.1:$port/jmap",{headers=>{
    'Content-Type'=>'application/json',Authorization=>"Basic $auth"},
    content=>encode_json({using=>['urn:ietf:params:jmap:core','urn:ietf:params:jmap:mail','urn:ietf:params:jmap:submission'],methodCalls=>$calls})});
}
my $q=['Email/query',{accountId=>'synthetic',limit=>1},'q'];
my $warm=query([$q]);
for (1..30) {
  last if $warm->{content}=~/"Email\/query"/;
  sleep .1;$warm=query([$q]);
}
like($warm->{content},qr/"Email\/query"/,'cold ordinary request completes as JMAP success, not just HTTP 200');
my $metrics=$http->get("http://127.0.0.1:$mgmt/metrics")->{content};
like($metrics,qr/jmap_operation_seconds_count\{role="api",stage="sql"\}/,'real worker SQL timings reach parent');
unlike($metrics,qr/synthetic\@|synthetic-only/,'telemetry contains no address or password');

open my $lock,'>',"$dir/synthetic.lock" or die $!;
flock($lock,LOCK_EX) or die $!;
my $started=time();
my $timeout=query([$q]);
cmp_ok(time()-$started,'<',4,'blocked safe read fails within bounded deadline');
unlike($timeout->{content},qr/"Email\/query"/,'expired read is not reported as successful query');
flock($lock,LOCK_UN);close $lock;
sleep 1.2; # bounded respawn backoff: new worker then starts cleanly
my $retry=query([$q]);
for (1..30) {
  last if $retry->{content}=~/"Email\/query"/;
  sleep .1;$retry=query([$q]);
}
like($retry->{content},qr/"Email\/query"/,'reader actually recovers without restarting proxy, not just an HTTP 200 error');
$metrics=$http->get("http://127.0.0.1:$mgmt/metrics")->{content};
like($metrics,qr/jmap_backend_read_timeouts_total 1/,'expired real request counted once');
is($http->get("http://127.0.0.1:$mgmt/healthz")->{status},200,'HTTP parent remains responsive after terminating blocked read');

# A timed-out read behind a write may release its HTTP caller, but must never
# kill that serial worker or cause an automatic mutation replay.
my ($signals_before)=$metrics=~/jmap_worker_exits_total\{role="api",outcome="signal"\} (\d+)/;
$signals_before //= 0;
open $lock,'>',"$dir/synthetic.lock" or die $!;flock($lock,LOCK_EX) or die $!;
my $writer=fork();die $! unless defined $writer;
if (!$writer) {
  $pid=0; # this client does not own the proxy's END cleanup
  my $reply=query([['Identity/set',{accountId=>'synthetic',update=>{id1=>{textSignature=>'deadline-survived'}}},'w']]);
  open my $f,'>',"$dir/write-result.json" or die $!;print $f encode_json($reply);close $f;
  exit 0;
}
my $write_queued=0;
for (1..20) {
  my $m=$http->get("http://127.0.0.1:$mgmt/metrics")->{content};
  if ($m=~/jmap_backend_queue_depth [1-9]/) {$write_queued=1;last}
  sleep .02;
}
ok($write_queued,'mutation is admitted before the read is queued');
my $queued_read=query([$q]);
unlike($queued_read->{content},qr/"Email\/query"/,'read behind blocked mutation expires');
ok(!-f "$dir/write-result.json",'mutation has not returned a premature failure');
flock($lock,LOCK_UN);close $lock;
waitpid $writer,0;
is($?,0,'mutation client completes after releasing the lock');
open my $wf,'<',"$dir/write-result.json" or die $!;
my $wr=do {local $/;decode_json(<$wf>)};close $wf;
like($wr->{content},qr/"Identity\/set"/,'the original mutation is answered without replay');
like(query([['Identity/get',{accountId=>'synthetic',ids=>['id1']},'g']])->{content},
  qr/deadline-survived/,'mutation persisted after the queued read expired');
$metrics=$http->get("http://127.0.0.1:$mgmt/metrics")->{content};
my ($signals_after)=$metrics=~/jmap_worker_exits_total\{role="api",outcome="signal"\} (\d+)/;
is($signals_after // 0,$signals_before,'deadline did not terminate worker containing a mutation');
done_testing;
