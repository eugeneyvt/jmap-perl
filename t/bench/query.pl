use strict;
use warnings;
use JSON::XS;
use Time::HiRes qw(time);
use Digest::SHA qw(sha256_hex);
use JMAP::ImapDB;
use JMAP::API;
die "Explicit synthetic benchmark opt-in and data directory required\n"
  unless ($ENV{JMAP_BENCHMARK}//'') eq 'synthetic' && $ENV{JMAP_DATADIR};
my ($action,$arg)=@ARGV;
my $marker="$ENV{JMAP_DATADIR}/.synthetic-query-benchmark";
my $json=JSON::XS->new->canonical->utf8;
{
  package BenchmarkMailbox;
  use parent 'JMAP::ImapDB';
  sub backend_cmd {
    my ($self,$cmd,$folder)=@_;
    die 'Unexpected provider command' unless $cmd eq 'imap_search';
    $self->{provider_calls}++;
    return ['search',$folder,1,[map {$_*100} 1..500]];
  }
}
if (($action//'') eq 'seed') {
  die 'Seed target must be an unused synthetic directory' if -e $marker || -e "$ENV{JMAP_DATADIR}/benchmark.sqlite3";
  die 'Invalid fixture size' unless defined($arg) && $arg=~/^\d+$/ && $arg>=50000 && $arg<=1000000;
  my $db=BenchmarkMailbox->new('benchmark');
  $db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
  $db->begin;
  $db->dinsert('ifolders',{ifolderid=>1,jmailboxid=>'inbox',imapname=>'INBOX',sep=>'/',label=>'INBOX',uidfirst=>1,uidnext=>$arg+1,uidvalidity=>1});
  my $message=$db->dbh->prepare('INSERT INTO jmessages(msgid,thrid,internaldate,msgdate,msgsize,keywords,msgsubject,sortsubject,msgfrom,msgto,active,jmodseq)
    VALUES(?,?,?,?,?,?,?,?,?,?,1,1)');
  my $member=$db->dbh->prepare('INSERT INTO jmessagemap(jmailboxid,msgid,active) VALUES(?,?,1)');
  my $imap=$db->dbh->prepare('INSERT INTO imessages(ifolderid,uid,msgid,mtime) VALUES(1,?,?,1)');
  for my $n (1..$arg) {
    my $id=sprintf('m%09d',$n);
    $message->execute($id,'t'.int($n/4),$n,$n,1024,'{}','Synthetic subject '.('x'x640),'synthetic subject',
      'synthetic@example.invalid','recipient@example.invalid');
    $member->execute($n%3 ? 'inbox' : 'other',$id);$imap->execute($n,$id);
  }
  $db->commit;
  open my $f,'>',$marker or die $!;print $f "$arg\n";close $f;
  print $json->encode({seed_rows=>0+$arg}),"\n";
  exit;
}
die 'Synthetic fixture marker missing' unless -f $marker;
my $db=BenchmarkMailbox->new('benchmark');
exit if $action eq 'migrate';
die 'Unknown benchmark action' unless $action eq 'run' && ($arg eq 'folder' || $arg eq 'search');
my $api=JMAP::API->new($db);
my $filter=$arg eq 'folder' ? {inMailbox=>'inbox'} : {text=>'synthetic-hit',inMailbox=>'inbox'};
my @results;
for my $position (0,50,100,150) {
  my $start=time;
  my ($r)=$api->api_Email_query({accountId=>'benchmark',filter=>$filter,sort=>[{property=>'receivedAt',isAscending=>JSON::XS::false}],
    collapseThreads=>JSON::XS::true,position=>$position,limit=>50,calculateTotal=>JSON::XS::true});
  die 'Benchmark query failed' unless $r->[0] eq 'Email/query';
  push @results,{position=>$position,seconds=>time-$start,returned=>scalar @{$r->[1]{ids}},total=>$r->[1]{total},
    ids_sha256=>sha256_hex($json->encode($r->[1]{ids}))};
}
my %memory;
if (open my $s,'<','/proc/self/status') {
  while (<$s>) {$memory{$1}=0+$2 if /^(VmHWM|VmRSS|VmSwap):\s+(\d+)/}close $s;
}
print $json->encode({case=>$arg,queries=>\@results,process_memory_kib=>\%memory,provider_calls=>$db->{provider_calls}//0}),"\n";
