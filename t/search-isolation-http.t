use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use HTTP::Tiny;
use JSON::XS qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use Time::HiRes qw(time sleep);
use POSIX qw(WNOHANG);
use JMAP::ImapDB;

my $owner=$$;
my $dir=tempdir(CLEANUP=>1);
my @children;
sub free_port {
  my $s=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>0,Listen=>1,Proto=>'tcp') or die $!;
  return $s->sockport;
}
my ($port,$mgmt,$provider)=(free_port(),free_port(),free_port());
END {
  local $?;
  if ($$==$owner) {
    for my $pid (reverse @children) {
      kill 'TERM',$pid;
      my $end=time()+2;
      while(time()<$end) {last if waitpid($pid,WNOHANG)==$pid;sleep .02}
      if(kill(0,$pid)) {kill 'KILL',$pid;waitpid($pid,0)}
    }
  }
}
my $imap_pid=fork();die $! unless defined $imap_pid;
if (!$imap_pid) {
  my $server=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>$provider,Listen=>5,ReuseAddr=>1,Proto=>'tcp') or die $!;
  while(my $s=$server->accept()) {
    $s->autoflush(1);
    print $s "* OK [CAPABILITY IMAP4rev1 UNSELECT] synthetic\r\n";
    while(my $line=<$s>) {
      my ($tag,$command)=$line=~/^(\S+)\s+(.*)/;next unless $tag;
      if($command=~/^CAPABILITY/i) {print $s "* CAPABILITY IMAP4rev1 UNSELECT\r\n"}
      elsif($command=~/^EXAMINE/i) {print $s "* 1 EXISTS\r\n* OK [UIDVALIDITY 7]\r\n* OK [UIDNEXT 2]\r\n"}
      elsif($command=~/^(?:UID )?SEARCH/i) {
        open my $flag,'>',"$dir/search-entered" or die $!;close $flag;
        sleep 2;
        print $s "* SEARCH 1\r\n";
      }
      print $s "$tag OK completed\r\n";
    }
    close $s;
  }
  exit 0;
}
push @children,$imap_pid;
my $proxy_pid=fork();die $! unless defined $proxy_pid;
if(!$proxy_pid) {
  $ENV{JMAP_HOME}='.';$ENV{JMAP_DATADIR}=$dir;$ENV{JMAP_SECRET_KEY}='d'x64;
  $ENV{JMAP_PORT}=$port;$ENV{JMAP_MGMT_PORT}=$mgmt;
  $ENV{JMAP_HOST}='127.0.0.1';$ENV{JMAP_MGMT_HOST}='127.0.0.1';
  $ENV{BASEURL}="http://127.0.0.1:$port";
  $ENV{JMAP_READ_DEADLINE}=5;$ENV{JMAP_MAX_WORKERS}=3;
  $ENV{JMAP_IDLE_ENABLE}=0;$ENV{JMAP_SYNC_INTERVAL}=600;
  open STDOUT,'>',"$dir/proxy.log" or die $!;open STDERR,'>&',\*STDOUT or die $!;
  exec $^X,'-I.','bin/jmap-proxy.pl';die $!;
}
push @children,$proxy_pid;
my $http=HTTP::Tiny->new(timeout=>8,proxy=>undef,http_proxy=>undef,https_proxy=>undef);
my $alive;
for(1..60) {$alive=$http->get("http://127.0.0.1:$mgmt/healthz");last if $alive->{status}==200;sleep .1}
is($alive->{status},200,'real proxy is listening');
my $created=$http->post("http://127.0.0.1:$mgmt/api/accounts",{
 headers=>{'Content-Type'=>'application/json'},content=>encode_json({accountid=>'synthetic',email=>'test@example.invalid',type=>'imap'})});
is($created->{status},201,'synthetic account registered');
local $JMAP::DB::DATADIR=$dir;local $ENV{JMAP_SECRET_KEY}='d'x64;
my $db=JMAP::ImapDB->new('synthetic');
$db->setuser({username=>'test@example.invalid',password=>'synthetic',imapHost=>'127.0.0.1',imapPort=>$provider,imapSSL=>1});
$db->begin;
$db->dinsert('ifolders',{ifolderid=>1,jmailboxid=>'inbox',sep=>'/',imapname=>'INBOX',label=>'INBOX',uidvalidity=>7,uidfirst=>1,uidnext=>2});
$db->dmake('jmessages',{msgid=>'m1',thrid=>'t1',internaldate=>100,keywords=>'{}'});
$db->dinsert('imessages',{ifolderid=>1,uid=>1,msgid=>'m1'});
$db->dmake('jmessagemap',{msgid=>'m1',jmailboxid=>'inbox'});$db->commit;
my $auth=encode_base64('test@example.invalid:synthetic','');
sub query {
  my ($calls)=@_;
  return $http->post("http://127.0.0.1:$port/jmap",{headers=>{
   'Content-Type'=>'application/json',Authorization=>"Basic $auth"},
   content=>encode_json({using=>['urn:ietf:params:jmap:core','urn:ietf:params:jmap:mail','urn:ietf:params:jmap:submission'],methodCalls=>$calls})});
}
my $warm=query([['Email/query',{accountId=>'synthetic',limit=>1},'q']]);
like($warm->{content},qr/"Email\/query"/,'warm ordinary list succeeds');
my $search_pid=fork();die $! unless defined $search_pid;
if(!$search_pid) {
  my $r=query([['Email/query',{accountId=>'synthetic',filter=>{text=>'needle'},limit=>10},'q']]);
  open my $f,'>',"$dir/search-result.json" or die $!;print $f encode_json($r);close $f;exit 0;
}
push @children,$search_pid;
for(1..80) {last if -e "$dir/search-entered";sleep .05}
ok(-e "$dir/search-entered",'provider is deliberately blocked inside SEARCH');
my $start=time();
my $write=query([['Identity/set',{accountId=>'synthetic',update=>{id1=>{textSignature=>'while-searching'}}},'w']]);
like($write->{content},qr/"Identity\/set"/,'mutation succeeds while provider search is blocked');
cmp_ok(time()-$start,'<',1,'mutation does not wait behind the slow provider search');
$start=time();
my $list=query([['Email/query',{accountId=>'synthetic',limit=>1},'q']]);
like($list->{content},qr/"Email\/query"/,'ordinary list also succeeds during search');
cmp_ok(time()-$start,'<',1,'ordinary list does not wait behind provider search');
waitpid($search_pid,0);@children=grep {$_!=$search_pid} @children;
open my $f,'<',"$dir/search-result.json" or die $!;my $r=do {local $/;decode_json(<$f>)};
like($r->{content},qr/"Email\/query"/,'slow search completes without losing its response');
like($r->{content},qr/"m1"/,'search returns the matching seeded message');
like($http->get("http://127.0.0.1:$mgmt/metrics")->{content},qr/role="search"/,'search worker has distinct telemetry');
done_testing;
