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
done_testing;
