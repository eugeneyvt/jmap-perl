use strict;
use warnings;
use Test::More;
use JSON::XS qw(encode_json);
BEGIN {require File::Temp;$ENV{JMAP_DATADIR}=File::Temp::tempdir(CLEANUP=>1);$ENV{JMAP_SECRET_KEY}='c'x64}
use JMAP::ImapDB;
use JMAP::GmailDB;
use JMAP::API;
{
  package SearchTransportDB;
  use parent 'JMAP::ImapDB';
  sub backend_cmd {
    my ($self,$cmd,$folder,@search)=@_;
    die 'unexpected transport' unless $cmd eq 'imap_search';
    die 'network inside transaction' if $self->in_transaction;
    push @{$self->{calls}},[$folder,@search];
    if (delete $self->{race_once}) {
      $self->begin;$self->ddirty('jmessages',{keywords=>JSON::XS::encode_json({'$flagged'=>1})},{msgid=>'m1'});$self->commit;
    }
    die 'synthetic disconnected provider' if $self->{fail};
    my $value=$search[-1];
    my @uids=$value eq 'odd' ? (1,3,5,7) : $value eq 'tail' ? (1997..2000) : $value eq 'changed' ? (2,4) : (1..2000);
    @uids=(2,4) if $self->{changed};
    return ['search',$folder,$self->{bad_validity} ? 2 : 1,\@uids];
  }
  sub dgetfield {
    die 'per-UID metadata lookup is forbidden' if $_[1] eq 'imessages';
    return shift->SUPER::dgetfield(@_);
  }
  sub dget {
    die 'whole catalog materialization is forbidden' if $_[1] eq 'jmessages';
    return shift->SUPER::dget(@_);
  }
}
my $db=SearchTransportDB->new('provider');
$db->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
$db->begin;
$db->dinsert('ifolders',{ifolderid=>1,jmailboxid=>'inbox',sep=>'/',imapname=>'INBOX',label=>'INBOX',uidvalidity=>1,uidfirst=>1,uidnext=>2001});
my $m=$db->dbh->prepare('INSERT INTO jmessages(msgid,thrid,internaldate,keywords,active,jmodseq) VALUES(?,?,?,?,1,1)');
my $i=$db->dbh->prepare('INSERT INTO imessages(ifolderid,uid,msgid,mtime) VALUES(1,?,?,1)');
my $b=$db->dbh->prepare('INSERT INTO jmessagemap(jmailboxid,msgid,active) VALUES(?,?,1)');
for my $n (1..2000) {
  $m->execute("m$n",'t'.int(($n-1)/2),$n,encode_json($n==2 ? {'$flagged'=>1} : {}));
  $i->execute($n,"m$n");$b->execute($n%2 ? 'inbox' : 'other',"m$n");
}
$db->commit;
my $api=JMAP::API->new($db);
sub query {my ($filter,@extra)=@_;return $api->api_Email_query({accountId=>'provider',filter=>$filter,
  sort=>[{property=>'receivedAt',isAscending=>JSON::XS::false}],limit=>20,@extra})}
my $first=query({text=>'odd',inMailbox=>'inbox'});
is_deeply($first->[1]{ids},[qw(m7 m5 m3 m1)],'provider IDs are filtered and sorted locally without materializing all metadata');
is(scalar @{$db->{calls}},1,'one provider call for the initial search');
query({text=>'odd',inMailbox=>'inbox'},position=>2);
is(scalar @{$db->{calls}},1,'a second page uses the bounded fresh snapshot');
my $or=query({operator=>'OR',conditions=>[{text=>'tail'},{inMailbox=>'inbox'}]});
is_deeply([@{$or->[1]{ids}}[0..4]],[qw(m2000 m1999 m1998 m1997 m1995)],'OR retains non-provider local matches');
my $not=query({operator=>'NOT',conditions=>[{text=>'odd'}]},limit=>3);
is_deeply($not->[1]{ids},[qw(m2000 m1999 m1998)],'NOT complements against the whole active account');
my $thread=query({operator=>'AND',conditions=>[{text=>'odd'},{inMailbox=>'inbox'},{someInThreadHaveKeyword=>'$flagged'}]});
is_deeply($thread->[1]{ids},['m1'],'thread-wide predicate sees the flagged sibling in another mailbox and outside provider hits');
my $before=scalar @{$db->{calls}};
query({operator=>'OR',conditions=>[{body=>'odd'},{body=>'odd'}]});
is(scalar(@{$db->{calls}})-$before,1,'duplicate search leaves share one provider lookup');
my $header=query({header=>['X-Test']},limit=>1);
is($db->{calls}[-1][-1],'','header existence preserves the provider HEADER name empty-value form');
$db->begin;$db->dbh->do('UPDATE jemailqueries SET created=created-11 WHERE state=?',{},$first->[1]{queryState});$db->commit;
$before=scalar @{$db->{calls}};
my $refreshed=query({text=>'odd',inMailbox=>'inbox'});
is(scalar(@{$db->{calls}})-$before,1,'expired provider freshness triggers a new search');
is($refreshed->[1]{queryState},$first->[1]{queryState},'fresh identical result renews safely without duplicate snapshot key');
$db->begin;$db->dbh->do('UPDATE jemailqueries SET created=created-11 WHERE state=?',{},$first->[1]{queryState});$db->commit;
$db->{changed}=1;
my $changed=query({text=>'odd',inMailbox=>'inbox'});
isnt($changed->[1]{queryState},$first->[1]{queryState},'changed provider results invalidate queryState even without local metadata changes');
is_deeply($changed->[1]{ids},[],'new provider results are combined with current mailbox membership');
$db->{changed}=0;$db->{bad_validity}=1;
eval {query({text=>'uncached-validity'})};
like($@,qr/UIDVALIDITY changed/,'UIDVALIDITY mismatch fails instead of publishing a partial empty result');
$db->{bad_validity}=0;$db->{fail}=1;
eval {query({text=>'uncached-failure'})};
like($@,qr/disconnected provider/,'transport error is not cached as an empty search');
$db->{fail}=0;
my $race_start=scalar @{$db->{calls}};
$db->{race_once}=1;
my $raced=query({text=>'raced',hasKeyword=>'$flagged'});
is_deeply($raced->[1]{ids},[qw(m2 m1)],'provider search racing a local commit uses the new consistent metadata state');
is(scalar(@{$db->{calls}})-$race_start,2,'provider candidates are retried when their catalog state changes');
my $legacy=$db->imap_search('text','tail');
is_deeply([sort keys %$legacy],[qw(m1997 m1998 m1999 m2000)],'compatibility search adapter also uses batch UID mapping');

# Gmail retains its current x-gm-raw language and folder scope exactly.
my $gmail=SearchTransportDB->new('gmail-fixture');$gmail->{is_gmail}=1;
$gmail->setuser({username=>'synthetic',password=>'synthetic',imapHost=>'example.invalid'});
$gmail->begin;
for my $f ([1,'All Mail','\\AllMail'],[2,'Trash','\\Trash'],[3,'Spam','\\Junk']) {
  $gmail->dinsert('ifolders',{ifolderid=>$f->[0],imapname=>$f->[1],label=>$f->[2],sep=>'/',uidvalidity=>1,uidfirst=>1,uidnext=>2});
}
$gmail->commit;
$gmail->prepare_provider_query([['text','has:attachment newer_than:1d']]);
is_deeply([map {$_->[0]} @{$gmail->{calls}}],['All Mail','Trash'],'existing Gmail All Mail/Trash scope is preserved');
is_deeply([@{$gmail->{calls}[0]}[-2,-1]],['x-gm-raw','has:attachment newer_than:1d'],'Gmail syntax reaches provider unchanged');
done_testing;
