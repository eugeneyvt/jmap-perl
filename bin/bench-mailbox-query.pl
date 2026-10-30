#!/usr/bin/perl
use strict;
use warnings;
use lib '.';
use JMAP::API;
use JMAP::ImapDB;
use JSON::XS;
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(time);

# Only run against a private disposable cache copy in a network-isolated
# container. save_query writes query-state records, so a live mount is forbidden.
die "Benchmark requires an explicitly marked disposable cache\n"
  unless -f "$ENV{JMAP_DATADIR}/.disposable-query-benchmark";
{
  package BenchmarkGeneralAPI;
  use parent 'JMAP::API';
  sub _mailbox_query_rows { undef }
}
my $json=JSON::XS->new->utf8->canonical;
my @results;
for my $account ('gmail','yandex') {
  my $db=JMAP::ImapDB->new($account);
  $db->begin();
  my ($inbox)=$db->dbh->selectrow_array("SELECT jmailboxid FROM jmailboxes WHERE active=1 AND role='inbox'");
  my ($count)=$db->dbh->selectrow_array('SELECT COUNT(*) FROM jmessages WHERE active=1');
  $db->commit();
  die "Inbox unavailable in benchmark copy\n" unless $inbox;
  my $fast=JMAP::API->new($db);
  my $old=BenchmarkGeneralAPI->new($db);
  for my $profile ('all','unread') {
    my $params={accountId=>$account,sort=>[{property=>'receivedAt',isAscending=>JSON::XS::false}],
      filter=>$profile eq 'all' ? {inMailbox=>$inbox} :
        {operator=>'AND',conditions=>[{inMailbox=>$inbox},{notKeyword=>'$seen'}]},
      collapseThreads=>JSON::XS::true,limit=>26};
    my $query=sub {
      my ($api)=@_;
      my $started=time();
      my @response=$api->api_Email_query($params);
      my $seconds=time()-$started;
      die "Benchmark query failed\n" unless $response[0][0] eq 'Email/query';
      return ($seconds,$json->encode(\@response));
    };
    # Warm both paths before alternating timed samples over identical data.
    $query->($old); $query->($fast);
    my (@baseline,@candidate,$fingerprint);
    for (1..3) {
      my ($old_seconds,$old_response)=$query->($old);
      my ($new_seconds,$new_response)=$query->($fast);
      die "Optimized query response differs from the general path\n" unless $old_response eq $new_response;
      $fingerprint=sha256_hex($new_response);
      push @baseline,$old_seconds;
      push @candidate,$new_seconds;
    }
    my $median=sub { my @values=sort {$a<=>$b} @_; return $values[int(@values/2)] };
    my $before=$median->(@baseline);
    my $after=$median->(@candidate);
    push @results,{account=>$account,profile=>$profile,active_messages=>$count,
      baseline_seconds=>[map {0+sprintf('%.6f',$_)} @baseline],
      candidate_seconds=>[map {0+sprintf('%.6f',$_)} @candidate],
      median_speedup=>0+sprintf('%.2f',$before/$after),
      responses_identical=>JSON::XS::true,response_sha256=>$fingerprint};
  }
}
print $json->encode({cache_copy_only=>JSON::XS::true,network=>'none',results=>\@results}),"\n";
