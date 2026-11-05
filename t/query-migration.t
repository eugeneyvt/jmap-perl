use strict;
use warnings;
use Test::More;
use DBI;
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='f'x64}
use JMAP::ImapDB;
my $db=JMAP::ImapDB->new('migrate-query');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
$db->begin;
$db->dmake('jmessages',{msgid=>'preserved',thrid=>'conversation',keywords=>'{}'});
$db->dbh->do("INSERT INTO jdelivery(jsubid,state,updated,error_code) VALUES('held','unknown',1,'fixture')");
my $message=$db->dgetone('jmessages',{msgid=>'preserved'});
my $account;
my $credentials=$db->dgetone('iserver');
my $delivery=$db->dbh->selectall_arrayref('SELECT * FROM jdelivery');
for my $table (qw(jemailqueryrows jemailqueries jemailsummary jemailqueryclock)) {$db->dbh->do("DROP TABLE $table")}
for my $index (qw(jemailreceivedasc jemailreceiveddesc jemailthreadactive jemailmembership jemailmodseq)) {$db->dbh->do("DROP INDEX $index")}
$db->dbh->do('PRAGMA user_version=13');$db->commit;
$db->begin_read;$account={%{$db->get_user}};$db->commit;
$db->write_subdir('outbox','held.eml','synthetic held bytes');
$db=JMAP::ImapDB->new('migrate-query');$db->begin_read;
is(($db->dbh->selectrow_array('PRAGMA user_version'))[0],15,'v13 upgrades to current schema15');
is_deeply($db->dgetone('jmessages',{msgid=>'preserved'}),$message,'message identity and metadata survive the upgrade');
is_deeply($db->get_user,$account,'committed account states are not replaced');
is_deeply($db->dgetone('iserver'),$credentials,'encrypted provider settings are not replaced');
is_deeply($db->dbh->selectall_arrayref('SELECT * FROM jdelivery'),$delivery,'uncertain SMTP journal remains untouched');
is(($db->dbh->selectrow_array('PRAGMA quick_check'))[0],'ok','migrated database passes SQLite quick_check');
$db->commit;
is($db->read_subdir('outbox','held.eml'),'synthetic held bytes','held SMTP bytes are retained');
$db=JMAP::ImapDB->new('migrate-query');$db->begin_read;
is(($db->dbh->selectrow_array('PRAGMA user_version'))[0],15,'reopen does not reapply schema migration');$db->commit;

# An interrupted DDL migration must keep v13 and all old mail, not a partial v14.
my $bad=JMAP::ImapDB->new('failed-query-migration');$bad->begin;
$bad->dmake('jmessages',{msgid=>'still-here',thrid=>'still-here',keywords=>'{}'});
for my $table (qw(jemailqueryrows jemailqueries jemailsummary jemailqueryclock)) {$bad->dbh->do("DROP TABLE $table")}
$bad->dbh->do('PRAGMA user_version=13');$bad->commit;
my $raw=DBI->connect("dbi:SQLite:dbname=$ENV{JMAP_DATADIR}/failed-query-migration.sqlite3",undef,undef,{RaiseError=>1,PrintError=>0});
$raw->{Callbacks}={do=>sub {die "injected DDL failure\n" if $_[1]=~/CREATE TABLE IF NOT EXISTS jemailsummary/;return}};
eval {$bad->_initdb($raw)};
like($@,qr/migration to v14 failed/,'DDL failure aborts migration explicitly');
is(($raw->selectrow_array('PRAGMA user_version'))[0],13,'failed DDL does not advance schema version');
is(($raw->selectrow_array("SELECT count(*) FROM sqlite_master WHERE name='jemailqueryclock'"))[0],0,'earlier DDL in failed migration is rolled back');
is(($raw->selectrow_array("SELECT msgid FROM jmessages"))[0],'still-here','failed migration preserves original mail');
$raw->{Callbacks}=undef;$raw->disconnect;
$bad=JMAP::ImapDB->new('failed-query-migration');$bad->begin_read;
is(($bad->dbh->selectrow_array('PRAGMA user_version'))[0],15,'a clean retry recovers after the failed migration');$bad->commit;
done_testing;
