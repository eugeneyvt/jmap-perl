use strict;
use warnings;
use Test::More;
use DBI;
use IO::Select;
use Time::HiRes qw(time);
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='e'x64}
use JMAP::ImapDB;
my $db=JMAP::ImapDB->new('transactions');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
my $first=$db->_connection;
$db->begin;$db->get_user;$db->commit;
is($db->_connection,$first,'successful transactions reuse one connection inside a worker');
$db->begin_read;
eval {$db->dbh->do("UPDATE account SET displayname='forbidden'")};
like($@,qr/readonly/,'read transaction rejects writes at the SQLite boundary');
$db->rollback;

pipe(my $ready,my $signal) or die $!;
pipe(my $result,my $report) or die $!;
my $child=fork();die $! unless defined $child;
if (!$child) {
  close $signal;close $result;
  my $byte;read($ready,$byte,1);
  eval {$db->begin_read;my $u=$db->get_user;$db->commit;print $report "R\n";close $report};
  exit($@ ? 1 : 0);
}
close $ready;close $report;
$db->begin_read;$db->get_user;
print $signal 'G';close $signal;
my @readable=IO::Select->new($result)->can_read(3);
ok(@readable,'a second forked reader completes while the first read lock remains held');
$db->commit;
my $answer=<$result>;close $result;
waitpid($child,0);is($?,0,'forked reader uses a fresh connection and exits cleanly');
is($answer,"R\n",'concurrent read returned actual data');

$db->begin;my $base=$db->get_user->{jhighestmodseq};$db->commit;
my @children;
for my $worker (1..3) {
  my $pid=fork();die $! unless defined $pid;
  if (!$pid) {
    eval {
      for my $i (1..25) {$db->begin;$db->dmake('jmessages',{msgid=>"w$worker-$i",thrid=>"w$worker-$i",keywords=>'{}'});$db->commit}
    };
    exit($@ ? 1 : 0);
  }
  push @children,$pid;
}
for (@children) {waitpid($_,0);is($?,0,'concurrent writer finished without lost updates')}
$db->begin_read;
my ($count,$distinct)=$db->dbh->selectrow_array('SELECT COUNT(*),COUNT(DISTINCT jmodseq) FROM jmessages');
is($count,75,'all concurrent writes are preserved');
is($distinct,75,'every write has its own serialized modseq');
is($db->get_user->{jhighestmodseq}-$base,75,'account state advances once per committed mutation');
my ($journal)=$db->dbh->selectrow_array('PRAGMA journal_mode');
is(lc($journal),'delete','read/write separation does not switch WAL on');
$db->commit;

my $external=DBI->connect("dbi:SQLite:dbname=$ENV{JMAP_DATADIR}/transactions.sqlite3",undef,undef,{RaiseError=>1,PrintError=>0});
$external->do('BEGIN IMMEDIATE');
$db->_connection->sqlite_busy_timeout(100);
my $started=time;
eval {$db->begin;$db->get_user};
like($@,qr/locked/,'unexpected SQLite writer fails explicitly after busy timeout');
cmp_ok(time-$started,'<',2,'busy wait is bounded');
$db->reset;$external->do('ROLLBACK');$external->disconnect;
$db->begin;$db->get_user;$db->commit;
pass('clean connection recovers after a database lock error');
done_testing;
