use strict;
use warnings;
use Test::More;
use JSON::XS qw(encode_json);
use JMAP::RuntimePolicy;
use JMAP::RuntimeHealth;
my $h=JMAP::RuntimeHealth->new();
my $p=JMAP::RuntimePolicy->new(clock=>sub {100});
my %args=(accounts=>{'private@example.invalid'=>1},sync_times=>{'private@example.invalid'=>90},
  discovered=>1,now=>100,policy=>$p,max_sync_age=>120,max_request_age=>120,min_free_bytes=>1000);
ok(!$h->readiness(%args)->{ready},'unknown capacity is not silently healthy');
$h->ingest('private@example.invalid:sync',{free_bytes=>2000,sampled_at=>100,
  timings=>{imap=>{seconds=>2,count=>3,max_seconds=>1},'SELECT private'=>{seconds=>999}},
  counters=>{cache_corrupt=>1,'private password'=>99}});
ok($h->readiness(%args)->{ready},'fresh successful sync with capacity is ready');
$h->observe_oom(10,100);$h->observe_oom(11,101);
ok(!$h->readiness(%args,now=>102)->{ready},'new OOM makes readiness fail even while parent responds');
$h->ingest('private@example.invalid:sync',{free_bytes=>2000,sampled_at=>400});
ok($h->readiness(%args,now=>402,sync_times=>{'private@example.invalid'=>400})->{ready},'readiness recovers after quiet period with fresh progress');
ok(!$h->readiness(%args,now=>500)->{ready},'stale synchronization is not ready');
$h->{requests}++;$h->exited('private@example.invalid:sync',9);
my $metrics=join "\n",$h->metrics;
like($metrics,qr/jmap_worker_exits_total\{role="sync",outcome="signal"\} 1/,'signal exit is retained');
like($metrics,qr/jmap_backend_admitted_total 1/,'request counter survives worker disappearance');
unlike($metrics,qr/private|password|SELECT/,'metrics only contain fixed labels');
unlike(encode_json($h->readiness(%args)),qr/private\@/,'readiness does not expose account address');
my %replica_args=(%args,now=>402,sync_times=>{'private@example.invalid'=>400});
$h->ingest('private@example.invalid:sync',{replica=>{mode=>'provider',ready=>0,pending=>10,generation=>2,inventory_complete=>0},sampled_at=>402});
ok($h->readiness(%replica_args)->{ready},'provider mode can remain ready during local backfill');
$h->ingest('private@example.invalid:sync',{replica=>{mode=>'local',ready=>0,pending=>1,generation=>2,inventory_complete=>1},sampled_at=>402});
ok(!$h->readiness(%replica_args)->{ready},'local mode reports incomplete index readiness');
$h->ingest('private@example.invalid:content',{replica=>{mode=>'local',ready=>1,pending=>0,generation=>3,inventory_complete=>1},sampled_at=>402});
ok($h->readiness(%replica_args)->{ready},'complete current local index can be ready');
is($h->readiness(%replica_args)->{index_status},'configured','readiness reports a configured replica');
my $replica_metrics=join "\n",$h->metrics;
like($replica_metrics,qr/jmap_replica_pending\{account_key="[a-f0-9]{16}"\} 0/,'private account-keyed replica metric');
unlike($replica_metrics,qr/private\@/,'replica metrics do not expose email addresses');
done_testing;
