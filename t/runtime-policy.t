use strict;
use warnings;
use Test::More;
use JMAP::RuntimePolicy;
my $now = 0;
my $p = JMAP::RuntimePolicy->new(clock => sub {$now}, random => sub {0},
  max_workers => 2, per_worker => 2, max_pending => 3, max_bytes => 100);
is($p->admission('a', 10, 0, 0), undef, 'first request admitted');
$p->add('#0', 'a', 'jmap', {methodCalls=>[['Email/query',{},'q']]}, 40);
ok($p->all_safe('a'), 'read batch can be terminated at deadline');
$p->add('#1', 'a', 'jmap', {methodCalls=>[['Email/query',{},'q'],['Email/set',{},'w']]}, 40);
ok(!$p->all_safe('a'), 'a mixed batch protects the entire worker from termination');
is($p->admission('a',1,1,1),'worker queue full','per-worker cap enforced');
is($p->admission('b',30,1,0),'queue byte limit','serialized payload budget enforced');
is($p->admission('c',1,2,0),'worker limit','fork count bounded');
$now = 20;
is($p->oldest_age('a'),20,'oldest queued request age is available');
$p->finish('#0');$p->finish('#1');
is($p->oldest_age(),0,'finished requests do not retain history');
$p->failed('a');
is($p->admission('a',1,0,0),'worker backoff','failure does not cause immediate respawn');
$now++;
is($p->admission('a',1,0,0),undef,'retry admitted after backoff');
$p->failed('a');
$now++;
is($p->admission('a',1,0,0),'worker backoff','repeated failure increases backoff');
$p->succeeded('a');
is($p->admission('a',1,0,0),undef,'successful work resets failure history');
for my $method ('MDN/send','Email/copy','Blob/upload','Calendar/refreshSynced','Whatever/get') {
  ok(!JMAP::RuntimePolicy::safe_read('jmap',{methodCalls=>[[$method,{},'x']]}),"$method is not cancellable");
}
is(JMAP::RuntimePolicy::role('a:search'),'search','search timing has a bounded distinct role');
ok(JMAP::RuntimePolicy::provider_search('jmap',{methodCalls=>[
  ['Email/query',{filter=>{operator=>'AND',conditions=>[{text=>'example'}]}},'q'],
  ['Email/get',{'#ids'=>{resultOf=>'q',name=>'Email/query',path=>'/ids'}},'g']]}),
  'search and its result references stay together on the search worker');
ok(!JMAP::RuntimePolicy::provider_search('jmap',{methodCalls=>[
  ['Email/query',{filter=>{text=>'example'}},'q'],['Email/set',{update=>{}},'w']]}),
  'mixed search/mutation batch retains ordinary ordered dispatch');
ok(!JMAP::RuntimePolicy::provider_search('jmap',{methodCalls=>[
  ['Email/query',{filter=>{inMailbox=>'inbox',notKeyword=>'$seen'}},'q']]}),
  'ordinary unread listing does not wait on the provider search worker');
ok(!JMAP::RuntimePolicy::provider_search('jmap',{methodCalls=>[
  ['Whatever/query',{filter=>{text=>'example'}},'q']]}), 'unknown methods are not routed as safe search');
done_testing;
