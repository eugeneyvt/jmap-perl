use strict;
use warnings;
use Test::More;
use DBI;
use JSON::XS qw(encode_json);
BEGIN {
  require File::Temp;
  $ENV{JMAP_DATADIR} = File::Temp::tempdir(CLEANUP=>1);
  $ENV{JMAP_SECRET_KEY} = 'a' x 64;
}
use JMAP::ImapDB;
use JMAP::Telemetry;
my $db = JMAP::ImapDB->new('durable');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
my $notifications = 0;
$db->{change_cb} = sub {
  my ($object, $states) = @_;
  $notifications++;
  ok(!$object->in_transaction(), 'notification runs outside committed transaction');
  my $reader = DBI->connect("dbi:SQLite:dbname=$ENV{JMAP_DATADIR}/durable.sqlite3");
  my ($value) = $reader->selectrow_array("SELECT jstateEmail FROM account");
  is("$value", $states->{Email}, 'independent connection sees the advertised committed state');
};
$db->begin();
$db->dmake('jmessages',{msgid=>'one',thrid=>'one',keywords=>'{}'});
$db->commit();
is($notifications,1,'successful commit publishes once');
$db->begin();
$db->dmake('jmessages',{msgid=>'two',thrid=>'two',keywords=>'{}'});
$db->dbh->{Callbacks} = {commit=>sub {die "injected commit failure\n"}};
eval { $db->commit() };
like($@,qr/injected commit failure/,'commit failure propagates');
is($notifications,1,'failed commit does not publish uncommitted state');
$db->reset();
$db->{change_cb} = sub { die 'disconnected notification channel' };
$db->begin();
$db->dmake('jmessages',{msgid=>'three',thrid=>'three',keywords=>'{}'});
eval {$db->commit()};
is($@,'','notification failure does not make committed mutation appear rolled back');
$db->begin();
is($db->dgetfield('jmessages',{msgid=>'three'},'msgid'),'three','successful mutation retained');
is($db->dgetfield('jmessages',{msgid=>'two'},'msgid'),undef,'failed mutation rolled back');
$db->commit();
$db->write_subdir('parsed','bad.json','{"unfinished":');
is($db->read_parsed_msg('bad'),undef,'corrupt parsed data becomes a recoverable cache miss');
ok(-f "$ENV{JMAP_DATADIR}/durable/parsed/bad.json",'read does not destructively remove evidence');
my $metrics = JMAP::Telemetry::drain();
ok($metrics->{timings}{sql}{count}>0,'SQL work is measured');
ok($metrics->{counters}{notification_failed},'notification failure counted');
ok($metrics->{counters}{cache_corrupt},'cache corruption counted');
unlike(encode_json($metrics),qr/synthetic|jmessages|unfinished|SELECT/,'telemetry has no credentials, SQL or mail content');
{
  no warnings 'redefine';
  local *IO::LockedFile::new = sub {undef};
  eval {$db->begin()};
  like($@,qr/lock unavailable/,'missing account lock fails closed');
  ok(!$db->in_transaction(),'failure does not silently enter an unlocked transaction');
}
done_testing;
