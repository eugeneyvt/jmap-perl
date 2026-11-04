package JMAP::Replica;
use strict;
use warnings;
use DBI;
use DBD::SQLite::Constants qw(SQLITE_OPEN_READONLY);
use Digest::SHA qw(sha256_hex);
use JSON::XS;
use JMAP::AtomicFile;

my $json=JSON::XS->new->canonical->utf8;
our $PARSER_VERSION=1;

# Separate SSD database: a raw-storage timeout cannot hold the JMAP account
# writer lock. Journal mode remains DELETE; do not enable WAL on old runtimes.
sub new {
  my ($class,%args)=@_;
  die "Explicit replica database required\n" unless defined $args{path};
  return undef if $args{read_only} && !-f $args{path};
  my %options=(RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1,sqlite_use_immediate_transaction=>0);
  $options{sqlite_open_flags}=SQLITE_OPEN_READONLY if $args{read_only};
  my $dbh=DBI->connect("dbi:SQLite:dbname=$args{path}",undef,undef,\%options);
  $dbh->sqlite_busy_timeout(5000);$dbh->do('PRAGMA cache_size=-4096');$dbh->do('PRAGMA temp_store=FILE');
  my $self=bless {%args,dbh=>$dbh},$class;
  my ($version)=$dbh->selectrow_array('PRAGMA user_version');
  die "Unsupported replica database version\n" if $version>1 || ($args{read_only} && $version!=1);
  unless ($args{read_only}) {
    chmod(0600,$args{path}) or die "Cannot protect replica database\n";
    $self->_schema;
  }
  return $self;
}

sub _schema {
  my ($self)=@_;my $d=$self->{dbh};
  $d->begin_work;
  eval {
    $d->do("CREATE TABLE IF NOT EXISTS replica_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      generation INTEGER NOT NULL DEFAULT 0, mode TEXT NOT NULL DEFAULT 'provider',
      catalog_state TEXT, inventory_complete INTEGER NOT NULL DEFAULT 0, updated INTEGER NOT NULL DEFAULT 0,
      parser_version INTEGER NOT NULL DEFAULT 1)");
    $d->do('INSERT OR IGNORE INTO replica_state(singleton) VALUES(1)');
    $d->do("CREATE TABLE IF NOT EXISTS replica_jobs(identity TEXT PRIMARY KEY,msgid TEXT NOT NULL,
      folder INTEGER NOT NULL,uidvalidity INTEGER NOT NULL,uid INTEGER NOT NULL,bytes INTEGER NOT NULL,
      state TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,next_retry INTEGER NOT NULL DEFAULT 0,
      lease_token TEXT,lease_until INTEGER NOT NULL DEFAULT 0,sha256 TEXT,error_code TEXT,updated INTEGER NOT NULL,
      UNIQUE(folder,uidvalidity,uid))");
    $d->do('CREATE INDEX IF NOT EXISTS replica_due ON replica_jobs(state,next_retry,lease_until)');
    $d->do('CREATE INDEX IF NOT EXISTS replica_message ON replica_jobs(msgid,state)');
    $d->do('CREATE TABLE IF NOT EXISTS replica_scopes(folder INTEGER PRIMARY KEY,uidvalidity INTEGER NOT NULL,
      uidnext INTEGER NOT NULL,uidfirst INTEGER NOT NULL,checked INTEGER NOT NULL)');
    $d->do('CREATE TABLE IF NOT EXISTS replica_documents(msgid TEXT PRIMARY KEY,sha256 TEXT NOT NULL,
      parser_version INTEGER NOT NULL,preview TEXT NOT NULL,text_bytes INTEGER NOT NULL,payload TEXT,updated INTEGER NOT NULL)');
    $d->do("CREATE VIRTUAL TABLE IF NOT EXISTS replica_fts USING fts5(msgid UNINDEXED,subject,sender,recipients,
      cc,bcc,body,attachments,tokenize='unicode61 remove_diacritics 2')");
    my %state_columns=map {$_->[1]=>1} @{$d->selectall_arrayref('PRAGMA table_info(replica_state)')};
    $d->do('ALTER TABLE replica_state ADD COLUMN parser_version INTEGER NOT NULL DEFAULT 0') unless $state_columns{parser_version};
    my ($parser)=$d->selectrow_array('SELECT parser_version FROM replica_state WHERE singleton=1');
    die "Replica parser newer than this worker\n" if $parser>$PARSER_VERSION;
    if ($parser!=$PARSER_VERSION) {
      $d->do("UPDATE replica_jobs SET state='pending',next_retry=0 WHERE state='complete' AND NOT EXISTS(
        SELECT 1 FROM replica_documents d WHERE d.msgid=replica_jobs.msgid AND d.parser_version=? AND d.payload IS NOT NULL)",{},$PARSER_VERSION);
      $d->do('UPDATE replica_state SET parser_version=?,generation=generation+1 WHERE singleton=1',{},$PARSER_VERSION);
    }
    $d->do('PRAGMA user_version=1');
    $d->commit;1;
  } or do {my $e=$@;eval {$d->rollback};die $e};
}

sub state {$_[0]{dbh}->selectrow_hashref('SELECT * FROM replica_state WHERE singleton=1')}

sub coverage {
  my ($self,$catalog)=@_;
  my $state=$self->state;
  my ($pending)=$self->{dbh}->selectrow_array("SELECT count(*) FROM replica_jobs WHERE state NOT IN ('complete','obsolete')");
  return {%$state,pending=>$pending,ready=>($state->{inventory_complete} && !$pending &&
    ($state->{parser_version}//0)==$PARSER_VERSION && ($state->{catalog_state}//'') eq $catalog) ? 1 : 0};
}

sub catalog_token {
  my ($class,$db)=@_;
  my ($generation)=$db->dbh->selectrow_array('SELECT generation FROM jreplicacatalog WHERE singleton=1');
  my $folders=$db->dbh->selectall_arrayref('SELECT ifolderid,uidvalidity,uidfirst,uidnext FROM ifolders ORDER BY ifolderid');
  return sha256_hex($json->encode([$generation,$folders]));
}

sub seal_catalog {
  my ($self,$token,$complete)=@_;
  $self->{dbh}->do('UPDATE replica_state SET catalog_state=?,inventory_complete=?,updated=? WHERE singleton=1',{},$token,$complete?1:0,time());
}

sub set_mode {
  my ($self,$mode,$catalog)=@_;
  die "Invalid replica mode\n" unless $mode=~/^(provider|shadow|local)$/;
  die "Local search coverage incomplete\n" if $mode eq 'local' && !$self->coverage($catalog)->{ready};
  $self->{dbh}->do('UPDATE replica_state SET mode=?,generation=generation+1,updated=? WHERE singleton=1',{},$mode,time());
}

sub enqueue {
  my ($self,$row)=@_;
  for (qw(folder uidvalidity uid bytes)) {die "Invalid replica identity\n" unless defined($row->{$_}) && $row->{$_}=~/^\d+$/}
  die "Invalid replica message\n" unless length($row->{msgid}//'') && $row->{uid}>0 && $row->{uidvalidity}>0;
  my $identity=sha256_hex($json->encode([@$row{qw(folder uidvalidity uid)}]));
  my $old=$self->{dbh}->selectrow_hashref('SELECT msgid,bytes FROM replica_jobs WHERE identity=?',{},$identity);
  die "Immutable UID metadata changed\n" if $old && ($old->{msgid} ne $row->{msgid} || $old->{bytes}!=$row->{bytes});
  $self->{dbh}->do('INSERT OR IGNORE INTO replica_jobs(identity,msgid,folder,uidvalidity,uid,bytes,updated)
    VALUES(?,?,?,?,?,?,?)',{},$identity,@$row{qw(msgid folder uidvalidity uid bytes)},time());
  return $identity;
}

sub reconcile_catalog {
  my ($self,$db,$limit)=@_;
  $limit//=1000;die "Invalid reconciliation budget\n" unless $limit=~/^\d+$/ && $limit>0 && $limit<=10000;
  die "Reconciliation inside transaction\n" if $db->in_transaction;
  my $connection=$db->_connection;
  $connection->do('ATTACH DATABASE ? AS replica_queue',{},$self->{path});
  my (@queued,@obsolete,$missing,$token,$scopes);
  my $ok=eval {
    $db->begin_read;
    my $join='FROM imessages i JOIN ifolders f USING(ifolderid) JOIN jmessages m ON m.msgid=i.msgid WHERE m.active=1';
    my $absent=' AND NOT EXISTS(SELECT 1 FROM replica_queue.replica_jobs q
      WHERE q.folder=i.ifolderid AND q.uidvalidity=f.uidvalidity AND q.uid=i.uid AND q.state!=\'obsolete\')';
    my $cursor=$db->dbh->prepare('SELECT i.msgid,i.ifolderid AS folder,f.uidvalidity,i.uid,i.size AS bytes '.$join.$absent.
      ' ORDER BY i.internaldate DESC,i.imessageid LIMIT '.(0+$limit));
    $cursor->execute;while (my $row=$cursor->fetchrow_hashref) {push @queued,$row}$cursor->finish;
    ($missing)=$db->dbh->selectrow_array('SELECT count(*) '.$join.$absent);
    my $old=$db->dbh->prepare("SELECT q.identity FROM replica_queue.replica_jobs q WHERE q.state!='obsolete' AND NOT EXISTS(
      SELECT 1 FROM imessages i JOIN ifolders f USING(ifolderid) JOIN jmessages m ON m.msgid=i.msgid
      WHERE m.active=1 AND i.ifolderid=q.folder AND f.uidvalidity=q.uidvalidity AND i.uid=q.uid AND i.msgid=q.msgid) LIMIT ".(0+$limit));
    $old->execute;while (my ($id)=$old->fetchrow_array) {push @obsolete,$id}$old->finish;
    $token=__PACKAGE__->catalog_token($db);
    $scopes=$db->dbh->selectall_arrayref('SELECT ifolderid,uidvalidity,uidnext,uidfirst FROM ifolders',{Slice=>{}});
    $db->commit;1;
  };
  my $error=$@;
  eval {$db->rollback} if !$ok && $db->in_transaction;
  $connection->do('DETACH DATABASE replica_queue');
  die $error unless $ok;
  my $d=$self->{dbh};$d->do('BEGIN IMMEDIATE');
  eval {
    for my $row (@queued) {
      my $id=$self->enqueue($row);
      $d->do("UPDATE replica_jobs SET state='pending',next_retry=0 WHERE identity=? AND state='obsolete'",{},$id);
    }
    for my $id (@obsolete) {
      $d->do("UPDATE replica_jobs SET state='obsolete',lease_token=NULL,lease_until=0,error_code=NULL WHERE identity=?",{},$id);
    }
    $d->commit;1;
  } or do {my $e=$@;eval {$d->rollback};die $e};
  return {token=>$token,scopes=>$scopes,missing=>$missing-scalar(@queued),queued=>scalar(@queued),obsolete=>scalar(@obsolete)};
}

sub claim {
  my ($self,%args)=@_;my $d=$self->{dbh};my $now=$args{now}//time();
  my $lease=$args{lease}//300;die "Invalid replica lease\n" unless $lease>0;
  $d->do('BEGIN IMMEDIATE');
  my $job;
  eval {
    # An interrupted process is replayed; completed raw manifests are never
    # inferred from a checkpoint or from the existence of a remote filename.
    $job=$d->selectrow_hashref("SELECT * FROM replica_jobs WHERE
      (state IN ('pending','retry','raw') AND next_retry<=?) OR (state='leased' AND lease_until<=?)
      ORDER BY updated DESC,bytes ASC,identity LIMIT 1",{},$now,$now);
    if ($job) {
      my $token=sha256_hex(join(':',$$,rand(),$now,$job->{identity}));
      $d->do("UPDATE replica_jobs SET state='leased',lease_token=?,lease_until=?,attempts=attempts+1,updated=? WHERE identity=?",
        {},$token,$now+$lease,$now,$job->{identity});
      $job->{lease_token}=$token;$job->{attempts}++;$job->{lease_until}=$now+$lease;
    }
    $d->commit;1;
  } or do {my $e=$@;eval {$d->rollback};die $e};
  return $job;
}

sub _owned {
  my ($self,$job)=@_;
  my ($owned)=$self->{dbh}->selectrow_array("SELECT 1 FROM replica_jobs WHERE identity=? AND state='leased' AND lease_token=? AND lease_until>?",
    {},$job->{identity},$job->{lease_token},time());
  die "Replica lease lost\n" unless $owned;
}

sub raw_saved {
  my ($self,$job,$manifest)=@_;$self->_owned($job);
  die "Invalid verified manifest\n" unless ($manifest->{sha256}//'')=~/^[a-f0-9]{64}$/ && $manifest->{bytes}==$job->{bytes};
  $self->{dbh}->do('UPDATE replica_jobs SET sha256=?,updated=? WHERE identity=? AND lease_token=?',
    {},$manifest->{sha256},time(),$job->{identity},$job->{lease_token});
  $job->{sha256}=$manifest->{sha256};
}

sub complete {
  my ($self,$job,$doc)=@_;my $d=$self->{dbh};
  die "Raw manifest required before indexing\n" unless ($job->{sha256}//'')=~/^[a-f0-9]{64}$/;
  $d->do('BEGIN IMMEDIATE');
  eval {
    $self->_owned($job);
    # A legacy short-envelope ID collision cannot silently merge two originals.
    my ($old,$rowid)=$d->selectrow_array('SELECT sha256,rowid FROM replica_documents WHERE msgid=?',{},$job->{msgid});
    die "Replica message identity collision\n" if defined($old) && $old ne $job->{sha256};
    die "Complete parsed document required\n" unless ref($doc->{parsed}) eq 'HASH' &&
      ($doc->{parsed}{id}//'') eq $job->{msgid} && ref($doc->{parsed}{bodyStructure}) eq 'HASH' &&
      ref($doc->{parsed}{bodyValues}) eq 'HASH' && ref($doc->{parsed}{attachments}) eq 'ARRAY';
    my @fields=map {$doc->{$_}//''} qw(subject sender recipients cc bcc body attachments);
    $d->do('DELETE FROM replica_fts WHERE rowid=?',{},$rowid) if defined $rowid;
    $d->do('INSERT OR REPLACE INTO replica_documents(msgid,sha256,parser_version,preview,text_bytes,payload,updated) VALUES(?,?,?,?,?,?,?)',
      {},$job->{msgid},$job->{sha256},$PARSER_VERSION,substr($doc->{body}//'',0,256),length($json->encode(\@fields)),
      $doc->{parsed} ? $json->encode($doc->{parsed}) : undef,time());
    ($rowid)=$d->selectrow_array('SELECT rowid FROM replica_documents WHERE msgid=?',{},$job->{msgid});
    $d->do('INSERT INTO replica_fts(rowid,msgid,subject,sender,recipients,cc,bcc,body,attachments) VALUES(?,?,?,?,?,?,?,?,?)',
      {},$rowid,$job->{msgid},@fields);
    $d->do("UPDATE replica_jobs SET state='complete',lease_token=NULL,lease_until=0,error_code=NULL,updated=? WHERE identity=?",
      {},time(),$job->{identity});
    $d->do('UPDATE replica_state SET generation=generation+1,updated=? WHERE singleton=1',{},time());
    $d->commit;1;
  } or do {my $e=$@;eval {$d->rollback};die $e};
}

sub complete_alias {
  my ($self,$job)=@_;my $d=$self->{dbh};
  # Caller must establish provider-assigned Gmail identity. A verified current
  # document and a completed source are sufficient for another label alias;
  # it introduces no new bytes or index content, so needs no Box I/O or parse.
  $d->do('BEGIN IMMEDIATE');
  my $matched;
  eval {
    $self->_owned($job);
    my ($sha)=$d->selectrow_array("SELECT d.sha256 FROM replica_documents d
      JOIN replica_jobs q ON q.msgid=d.msgid AND q.sha256=d.sha256
      WHERE d.msgid=? AND d.parser_version=? AND d.payload IS NOT NULL
      AND q.state='complete' AND q.bytes=? LIMIT 1",{},$job->{msgid},$PARSER_VERSION,$job->{bytes});
    if ($sha) {
      die "Replica message identity collision\n" if $job->{sha256} && $job->{sha256} ne $sha;
      $d->do("UPDATE replica_jobs SET state='complete',sha256=?,lease_token=NULL,lease_until=0,error_code=NULL,updated=? WHERE identity=?",
        {},$sha,time(),$job->{identity});
      $matched=1;
    }
    $d->commit;1;
  } or do {my $e=$@;eval {$d->rollback};die $e};
  return $matched;
}

sub parsed_message {
  my ($self,$id)=@_;
  my ($payload)=$self->{dbh}->selectrow_array('SELECT payload FROM replica_documents WHERE msgid=? AND parser_version=?',{},$id,$PARSER_VERSION);
  return defined($payload) ? $json->decode($payload) : undef;
}

sub fail {
  my ($self,$job,$code)=@_;$self->_owned($job);
  die "Invalid replica error code\n" unless $code=~/^[a-z_]{1,64}$/;
  my $power=$job->{attempts}>8?8:$job->{attempts};
  $self->{dbh}->do("UPDATE replica_jobs SET state='retry',lease_token=NULL,lease_until=0,error_code=?,next_retry=?,updated=?
    WHERE identity=? AND lease_token=?",{},$code,time()+5*2**$power+int(rand(5)),time(),$job->{identity},$job->{lease_token});
}

sub search_sql {
  my ($class,$term)=@_;my ($field,$value,@rest)=@$term;
  my %columns=(text=>undef,subject=>'subject',from=>'sender',to=>'recipients',cc=>'cc',bcc=>'bcc',body=>'body');
  die "Unsupported local header search\n" unless exists $columns{$field};
  die "Invalid local search term\n" if ref($value) || !defined($value) || length($value)>4096;
  # JMAP text terms are data, never FTS syntax. Unquoted words are ANDed;
  # explicit quotes form a phrase. Provider-specific Gmail operators are not
  # silently reinterpreted as successful local searches.
  die "Provider-specific search syntax is unavailable locally\n" if $field eq 'text' && $value=~/(?:^|\s)[a-zA-Z]+:/;
  my @parts;
  while (length $value) {
    $value=~s/^\s+//;last unless length $value;
    my $part;
    if ($value=~s/^"([^"]*)"//) {$part=$1}
    elsif ($value=~s/^([^\s"]+)//) {$part=$1}
    else {die "Unclosed local search phrase\n"}
    next unless length $part;
    $part=~s/"/""/g;
    push @parts,(defined($columns{$field}) ? "$columns{$field} : " : '').'"'.$part.'"';
  }
  return @parts ? join(' AND ',@parts) : '""';
}

sub insert_hits {
  my ($self,$target,$terms,$table)=@_;
  $table//='jmap_provider_hits';die "Invalid local hit table\n" unless $table=~/^jmap_(provider|shadow)_hits$/;
  my $d=$self->{dbh};$d->begin_work;
  my $generation;
  my $attached=0;
  eval {
    $generation=$self->state->{generation};
    # Keep the replica snapshot pinned while SQLite copies result IDs directly
    # into the account's file-backed TEMP table. No Perl list/per-hit DBI loop.
    $target->do('ATTACH DATABASE ? AS replica_search',{},$self->{path});$attached=1;
    for my $index (0..$#$terms) {
      my $query=__PACKAGE__->search_sql($terms->[$index]);
      $target->do("INSERT OR IGNORE INTO temp.$table(term,msgid)
        SELECT ?,msgid FROM replica_search.replica_fts WHERE replica_fts MATCH ?",{},$index,$query);
    }
    $target->do('DETACH DATABASE replica_search');$attached=0;
    $d->commit;1;
  } or do {my $e=$@;eval {$target->do('DETACH DATABASE replica_search')} if $attached;eval {$d->rollback};die $e};
  return "local:$generation";
}
1;
