package JMAP::QueryStore;
use strict;
use warnings;
use JSON::XS;
use Digest::SHA qw(sha256_hex);
my $json = JSON::XS->new->utf8->canonical;

sub new {
  my ($class, $api, $args, $plan) = @_;
  my $self = bless {db=>$api->{db}, args=>$args, plan=>$plan}, $class;
  $self->{signature} = sha256_hex($json->encode({v=>2, account=>$api->{db}->accountid,
    scope=>$api->{query_scope} // 'account', resolved=>$plan->{binds},
    filter=>$args->{filter}, sort=>$args->{sort}, collapseThreads=>$args->{collapseThreads} ? 1 : 0}));
  for my $item ([ttl=>'JMAP_QUERY_TTL',3600], [max_rows=>'JMAP_QUERY_MAX_ROWS',250000],
      [max_bytes=>'JMAP_QUERY_MAX_BYTES',67108864], [max_snapshots=>'JMAP_QUERY_MAX_SNAPSHOTS',64],
      [provider_ttl=>'JMAP_PROVIDER_QUERY_TTL',10]) {
    my ($key,$env,$default)=@$item;
    my $v=$ENV{$env} // $default;
    die "Invalid query cache limit\n" unless $v =~ /^\d+$/ && $v > 0;
    $self->{$key}=0+$v;
  }
  return $self;
}

sub _begin_read {
  my ($self)=@_;
  my $db=$self->{db};
  $db->begin_read;
  unless ($db->get_user) {
    $db->commit;
    $db->begin; $db->get_user; $db->commit;
    $db->begin_read;
  }
}

sub _base {
  my ($self)=@_;
  my $db=$self->{db};
  my $user=$db->get_user;
  my ($generation)=$db->dbh->selectrow_array('SELECT generation FROM jemailqueryclock WHERE singleton=1');
  my $folders=@{$self->{plan}{terms}} ? $db->dbh->selectall_arrayref(
    'SELECT ifolderid,uidvalidity,uidfirst,uidnext,highestmodseq FROM ifolders ORDER BY ifolderid') : [];
  my $base=sha256_hex($json->encode({email=>$user->{jstateEmail}, mailbox=>$user->{jstateMailbox},
    generation=>$generation, account=>$db->accountid,folders=>$folders}));
  return ($base, $user->{jhighestmodseq});
}

sub _cached {
  my ($self,$base)=@_;
  return unless $self->_within_budget;
  my $age=@{$self->{plan}{terms}} ? $self->{provider_ttl} : $self->{ttl};
  $age=$self->{ttl} if $age>$self->{ttl};
  my $row=$self->{db}->dbh->selectrow_hashref('SELECT * FROM jemailqueries
    WHERE signature=? AND base_state=? AND created>=? ORDER BY created DESC LIMIT 1',{},
    $self->{signature},$base,time()-$age);
  return unless $row;
  return {%$row,table=>'jemailqueryrows',persistent=>1};
}

sub _within_budget {
  my ($self)=@_;
  my ($count,$rows,$bytes)=$self->{db}->dbh->selectrow_array(
    'SELECT COUNT(*),COALESCE(SUM(total),0),COALESCE(SUM(bytes),0) FROM jemailqueries');
  return $count<=$self->{max_snapshots} && $rows<=$self->{max_rows} && $bytes<=$self->{max_bytes};
}

sub _old {
  my ($self,$state)=@_;
  return unless defined($state) && $state =~ /^q2\.[a-f0-9]{64}$/;
  my $row=$self->{db}->dbh->selectrow_hashref('SELECT * FROM jemailqueries
    WHERE signature=? AND state=? AND created>=?',{},$self->{signature},$state,time()-$self->{ttl});
  my $floor=$self->{db}->get_user->{jdeletedmodseq} // 0;
  return if $row && $floor && $row->{modseq}<=$floor;
  return $row ? {%$row,table=>'jemailqueryrows',persistent=>1} : undef;
}

# Leave a transaction open so the caller's page/diff and its advertised state
# are read from one view. Provider work happens strictly between transactions.
sub _ensure {
  my ($self,$pin)=@_;
  my $db=$self->{db};
  for (1..3) {
    $self->_begin_read;
    my ($base)=$self->_base;
    if (my $hit=$self->_cached($base)) {return $hit}
    $db->commit;
    my $provider_digest='';
    if (@{$self->{plan}{terms}}) {
      die "Provider query requires IMAP adapter\n" unless $db->can('prepare_provider_query');
      $provider_digest=$db->prepare_provider_query($self->{plan}{terms});
    }
    $db->begin;
    my ($now_base,$modseq)=$self->_base;
    if (@{$self->{plan}{terms}} && $now_base ne $base) {
      $db->commit;
      next;
    }
    if (my $hit=$self->_cached($now_base)) {return $hit}
    my $state='q2.'.sha256_hex($json->encode([$self->{signature},$now_base,$provider_digest]));
    my $key=sha256_hex($self->{signature}.$state);
    my $dbh=$db->dbh;
    if ($self->_within_budget && (my $same=$dbh->selectrow_hashref('SELECT * FROM jemailqueries WHERE querykey=?',{},$key))) {
      # A fresh provider response can confirm an expired but identical result.
      # Keep the immutable rows/state rather than attempting a duplicate insert.
      $dbh->do('UPDATE jemailqueries SET created=?,used=? WHERE querykey=?',{},time(),time(),$key);
      return {%$same,table=>'jemailqueryrows',persistent=>1};
    }
    $dbh->do('DROP TABLE IF EXISTS temp.jmap_query_build');
    $dbh->do('CREATE TEMP TABLE jmap_query_build(querykey TEXT NOT NULL,position INTEGER PRIMARY KEY,msgid TEXT NOT NULL UNIQUE)');
    $dbh->do('INSERT INTO temp.jmap_query_build(position,msgid,querykey)
      SELECT position,msgid,? FROM ('.$self->{plan}{sql}.')',{},$key,@{$self->{plan}{binds}});
    my ($total,$bytes)=$dbh->selectrow_array('SELECT COUNT(*),COALESCE(SUM(2*length(msgid)+256),0) FROM temp.jmap_query_build');
    my $ref={querykey=>$key,signature=>$self->{signature},state=>$state,base_state=>$now_base,
      modseq=>$modseq,total=>$total,bytes=>$bytes,created=>time(),used=>time(),provider=>@{$self->{plan}{terms}} ? 1 : 0,
      table=>'temp.jmap_query_build',persistent=>0};
    if ($self->_make_room($total,$bytes,$pin)) {
      $dbh->do('INSERT INTO jemailqueries(querykey,signature,state,base_state,modseq,created,used,total,bytes,provider)
        VALUES(?,?,?,?,?,?,?,?,?,?)',{},map {$ref->{$_}} qw(querykey signature state base_state modseq created used total bytes provider));
      $dbh->do('INSERT INTO jemailqueryrows SELECT querykey,position,msgid FROM temp.jmap_query_build');
      $ref->{table}='jemailqueryrows'; $ref->{persistent}=1;
    }
    return $ref;
  }
  die "Mailbox changed during provider search; retry the query\n";
}

sub _drop_snapshot {
  my ($self,$key)=@_;
  $self->{db}->dbh->do('DELETE FROM jemailqueryrows WHERE querykey=?',{},$key);
  $self->{db}->dbh->do('DELETE FROM jemailqueries WHERE querykey=?',{},$key);
}

sub _make_room {
  my ($self,$rows,$bytes,$pin,$gc_only)=@_;
  my $dbh=$self->{db}->dbh;
  my $all=$dbh->selectall_arrayref('SELECT querykey,total,bytes,created FROM jemailqueries ORDER BY used,querykey',{Slice=>{}});
  for my $r (@$all) {
    $self->_drop_snapshot($r->{querykey}) if $r->{created}<time()-$self->{ttl} && (!defined($pin) || $r->{querykey} ne $pin);
  }
  my $oversize=$rows>$self->{max_rows} || $bytes>$self->{max_bytes};
  my ($reserve_count,$reserve_rows,$reserve_bytes)=($oversize || $gc_only) ? (0,0,0) : (1,$rows,$bytes);
  $all=$dbh->selectall_arrayref('SELECT querykey,total,bytes FROM jemailqueries ORDER BY used,querykey',{Slice=>{}});
  my ($count,$used_rows,$used_bytes)=(scalar(@$all),0,0);
  for (@$all) {$used_rows+=$_->{total};$used_bytes+=$_->{bytes}}
  for my $r (@$all) {
    last if $count+$reserve_count<=$self->{max_snapshots} && $used_rows+$reserve_rows<=$self->{max_rows} && $used_bytes+$reserve_bytes<=$self->{max_bytes};
    next if defined($pin) && $r->{querykey} eq $pin;
    $self->_drop_snapshot($r->{querykey}); $count--; $used_rows-=$r->{total};$used_bytes-=$r->{bytes};
  }
  return !$oversize && $count+$reserve_count<=$self->{max_snapshots} && $used_rows+$reserve_rows<=$self->{max_rows} && $used_bytes+$reserve_bytes<=$self->{max_bytes};
}

sub query {
  my ($self)=@_;
  my $ref=$self->_ensure;
  my $args=$self->{args};
  my $dbh=$self->{db}->dbh;
  my $start=$args->{position} // 0;
  if (defined $args->{anchor}) {
    my ($index)=$dbh->selectrow_array("SELECT position FROM $ref->{table} WHERE querykey=? AND msgid=?",{},$ref->{querykey},$args->{anchor});
    unless (defined $index) {$self->{db}->commit;return {error=>{type=>'anchorNotFound'}}}
    $start=$index+($args->{anchorOffset} // 0);
  }
  elsif ($start<0) {$start+=$ref->{total}}
  $start=0 if $start<0;
  my $limit=defined($args->{limit}) ? $args->{limit} : -1;
  my $ids=$dbh->selectcol_arrayref("SELECT msgid FROM $ref->{table} WHERE querykey=? AND position>=? ORDER BY position LIMIT ?",{},$ref->{querykey},$start,$limit);
  my $response={accountId=>$self->{db}->accountid,filter=>$args->{filter},sort=>$args->{sort},collapseThreads=>$args->{collapseThreads},
    queryState=>$ref->{state},canCalculateChanges=>$ref->{persistent} ? JSON::XS::true : JSON::XS::false,
    position=>$start,ids=>[map {"$_"} @$ids]};
  $response->{total}=0+$ref->{total} if $args->{calculateTotal};
  $self->{db}->commit;
  return $response;
}

sub changes {
  my ($self,$mutable)=@_;
  $mutable ||= 1 if @{$self->{plan}{terms}}; # Provider-native syntax may depend on flags/labels.
  my $args=$self->{args};my $db=$self->{db};
  $self->_begin_read;
  my $old=$self->_old($args->{sinceQueryState});
  $db->commit;
  return {error=>{type=>'cannotCalculateChanges'}} unless $old;
  my $new=$self->_ensure($old->{querykey});
  $old=$self->_old($args->{sinceQueryState});
  unless ($old) {$db->commit;return {error=>{type=>'cannotCalculateChanges'}}}
  my $dbh=$db->dbh;
  my @removed_bind=($old->{querykey},$new->{querykey});
  my $removed="SELECT o.msgid,o.position AS position,0 AS phase FROM jemailqueryrows o
    LEFT JOIN $new->{table} n ON n.querykey=? AND n.msgid=o.msgid WHERE o.querykey=? AND n.msgid IS NULL";
  @removed_bind=($new->{querykey},$old->{querykey});
  my $changed='0';
  if ($mutable) {
    $changed='COALESCE(m.jmodseq,0)>'.int($old->{modseq});
    if ($mutable==2) {
      $changed="($changed OR COALESCE(m.thrid,'') IN (SELECT COALESCE(t.thrid,'') FROM jmessages t WHERE t.jmodseq>".
        int($old->{modseq}).'))';
    }
    $removed.=" UNION ALL SELECT n.msgid,n.position,1 AS phase FROM $new->{table} n JOIN jmessages m ON m.msgid=n.msgid
      WHERE n.querykey=? AND $changed";
    push @removed_bind,$new->{querykey};
  }
  my $added="SELECT n.msgid,n.position FROM $new->{table} n LEFT JOIN jemailqueryrows o ON o.querykey=? AND o.msgid=n.msgid
    JOIN jmessages m ON m.msgid=n.msgid WHERE n.querykey=? AND (o.msgid IS NULL OR $changed)";
  my @added_bind=($old->{querykey},$new->{querykey});
  # Immutable-query upToId is an optional optimization. Returning every exact
  # removal/addition is permitted and keeps sparse client caches correct.
  my ($n_removed)=$dbh->selectrow_array("SELECT COUNT(*) FROM ($removed)",{},@removed_bind);
  my ($n_added)=$dbh->selectrow_array("SELECT COUNT(*) FROM ($added)",{},@added_bind);
  if (defined($args->{maxChanges}) && $n_removed+$n_added>$args->{maxChanges}) {
    $db->commit;return {error=>{type=>'tooManyChanges',newQueryState=>$new->{state}}};
  }
  my $r=$dbh->selectcol_arrayref("SELECT msgid FROM ($removed) ORDER BY phase,position",{},@removed_bind);
  my $a=$dbh->selectall_arrayref("$added ORDER BY n.position",{},@added_bind);
  my $response={accountId=>$db->accountid,filter=>$args->{filter},sort=>$args->{sort},collapseThreads=>$args->{collapseThreads},
    oldQueryState=>$args->{sinceQueryState},newQueryState=>$new->{state},removed=>[map {"$_"} @$r],
    added=>[map {{id=>"$_->[0]",index=>0+$_->[1]}} @$a]};
  $response->{total}=0+$new->{total} if $args->{calculateTotal};
  $self->_make_room(0,0,undef,1) unless $db->{t}{readonly};
  $db->commit;
  return $response;
}
1;
