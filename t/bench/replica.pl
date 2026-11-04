use strict;
use warnings;
use utf8;
use JSON::XS;
use Time::HiRes qw(time);
use Digest::SHA qw(sha256_hex);
use JMAP::ImapDB;
use JMAP::API;
use JMAP::Replica;
die "Explicit synthetic replica benchmark required\n" unless ($ENV{JMAP_BENCHMARK}//'') eq 'synthetic' && $ENV{JMAP_DATADIR};
my ($action,$size)=@ARGV;my $root=$ENV{JMAP_DATADIR};my $marker="$root/.synthetic-replica-benchmark";
my $json=JSON::XS->new->canonical->utf8;
{
  package ReplicaBenchmarkDB;
  use parent 'JMAP::ImapDB';
  sub backend_cmd {die 'Provider forbidden in local benchmark'}
}
if (($action//'') eq 'seed') {
  die "Unused synthetic target required\n" if -e $marker || -e "$root/benchmark.sqlite3";
  die "Fixture size must be 25k/100k/250k\n" unless $size==25000 || $size==100000 || $size==250000;
  my $db=ReplicaBenchmarkDB->new('benchmark');
  $db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
  mkdir "$root/benchmark" or die $!;
  my $r=JMAP::Replica->new(path=>"$root/benchmark/replica.sqlite3");
  $db->begin;$r->{dbh}->begin_work;
  $db->dinsert('ifolders',{ifolderid=>1,jmailboxid=>'inbox',imapname=>'INBOX',sep=>'/',label=>'INBOX',uidfirst=>1,uidnext=>$size+1,uidvalidity=>1});
  my $m=$db->dbh->prepare('INSERT INTO jmessages(msgid,thrid,internaldate,msgdate,msgsize,keywords,msgsubject,sortsubject,msgfrom,msgto,active,jmodseq)
    VALUES(?,?,?,?,1024,?, ?,?,?,?,1,1)');
  my $member=$db->dbh->prepare("INSERT INTO jmessagemap(jmailboxid,msgid,active) VALUES('inbox',?,1)");
  my $document=$r->{dbh}->prepare("INSERT INTO replica_documents(rowid,msgid,sha256,parser_version,preview,text_bytes,updated) VALUES(?,?,?,1,'synthetic',100,1)");
  my $fts=$r->{dbh}->prepare('INSERT INTO replica_fts(rowid,msgid,subject,sender,recipients,body,attachments) VALUES(?,?,?,?,?,?,?)');
  for my $n (1..$size) {
    my $id=sprintf('m%09d',$n);
    $m->execute($id,'t'.int($n/3),$n,$n,'{}','Synthetic fixture','synthetic fixture','sender@example.invalid','recipient@example.invalid');
    $member->execute($id);$document->execute($n,$id,sha256_hex($id));
    $fts->execute($n,$id,'Синтетическое письмо','sender@example.invalid','recipient@example.invalid',
      "общий текст order$n ".($n%100==0?'редкий заказ':''),'invoice.pdf');
  }
  $r->{dbh}->commit;$db->commit;
  $db->begin_read;my $token=JMAP::Replica->catalog_token($db);$db->commit;
  # Deliberate index-only synthetic fixture. No original-copy completeness is
  # asserted by this benchmark, and no real account path may be supplied.
  $r->seal_catalog($token,1);$r->set_mode('local',$token);
  open my $f,'>',$marker or die $!;print {$f} $size;close $f;
  print $json->encode({seed_rows=>0+$size,synthetic_index_only=>JSON::XS::true}),"\n";exit;
}
die "Synthetic fixture marker missing\n" unless -f $marker && ($action//'') eq 'run';
my $db=ReplicaBenchmarkDB->new('benchmark');my $api=JMAP::API->new($db);my @results;
for my $case ([folder=>{inMailbox=>'inbox'}],[selective=>{text=>'редкий заказ',inMailbox=>'inbox'}],[wide=>{text=>'общий'}]) {
  for my $position (0,25,50,75) {
    my $start=time;
    my ($result)=$api->api_Email_query({accountId=>'benchmark',filter=>$case->[1],
      sort=>[{property=>'receivedAt',isAscending=>JSON::XS::false}],position=>$position,limit=>25,calculateTotal=>JSON::XS::true});
    die "Benchmark query failed\n" unless $result->[0] eq 'Email/query';
    push @results,{case=>$case->[0],position=>$position,seconds=>time-$start,total=>$result->[1]{total},
      returned=>scalar @{$result->[1]{ids}},ids_sha256=>sha256_hex($json->encode($result->[1]{ids}))};
  }
}
my %memory;
if (open my $status,'<','/proc/self/status') {
  while (<$status>) {$memory{$1}=0+$2 if /^(VmHWM|VmRSS|VmSwap):\s+(\d+)/}close $status;
}
print $json->encode({queries=>\@results,process_memory_kib=>\%memory,provider_calls=>0}),"\n";
