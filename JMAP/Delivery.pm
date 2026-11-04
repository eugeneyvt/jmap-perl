package JMAP::Delivery;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use JSON::XS qw(encode_json);
use Errno qw(EPERM);
use JMAP::Telemetry;

# The journal is part of the account database. The SMTP side effect cannot be
# atomic with SQLite: persist intent before entering SMTP, and never retry an
# attempt whose acknowledgement may have been lost.
sub prepare {
  my ($class, $db, %args) = @_;
  my $fingerprint = sha256_hex(JSON::XS->new->canonical->encode([
    $args{msgid}, $args{identity}, $args{envelope}, sha256_hex($args{message})]));
  $db->begin();
  my $existing = $db->dbh->selectrow_hashref(
    "SELECT d.jsubid,d.state,s.sendat,s.undoStatus FROM jdelivery d JOIN jsubmission s
       ON s.jsubid=d.jsubid WHERE d.fingerprint=? AND d.state IN ('pending','prepared','sending','unknown')",
    {}, $fingerprint);
  if ($existing) {
    $db->commit();
    return $existing;
  }
  my $id = $db->dmake('jsubmission', {
    sendat=>$args{sendat}, msgid=>$args{msgid}, thrid=>$args{thrid},
    envelope=>encode_json($args{envelope}), identity=>$args{identity},
    undoStatus=>$args{held} ? 'pending' : 'final',
  });
  $db->dbh->do("INSERT INTO jdelivery (jsubid,state,fingerprint,body_sha256,updated)
    VALUES (?,'pending',?,?,?)", {}, $id, $fingerprint, sha256_hex($args{message}), time());
  # A crash before commit leaves, at most, an orphan complete file. The
  # converse (a ready committed job with no durable message) is forbidden.
  $db->write_subdir('outbox', "$id.eml", $args{message});
  $db->dbh->do("UPDATE jdelivery SET state='prepared',updated=? WHERE jsubid=?", {}, time(), $id);
  $db->commit();
  return {jsubid=>$id, state=>'prepared', sendat=>$args{sendat},
    undoStatus=>$args{held} ? 'pending' : 'final'};
}

sub send {
  my ($class, $db, $id) = @_;
  $db->begin();
  my $row = $db->dbh->selectrow_hashref(
    "SELECT d.*,s.undoStatus,s.envelope FROM jdelivery d JOIN jsubmission s
       ON s.jsubid=d.jsubid WHERE d.jsubid=?", {}, $id);
  unless ($row && $row->{state} eq 'prepared' && $row->{undoStatus} ne 'canceled') {
    $db->commit();
    return $row ? $row->{state} : 'missing';
  }
  my $message = $db->read_subdir('outbox', "$id.eml");
  unless (defined($message) && sha256_hex($message) eq $row->{body_sha256}) {
    $db->dbh->do("UPDATE jdelivery SET state='unknown',error_code='content_missing_or_corrupt',updated=? WHERE jsubid=?", {}, time(), $id);
    $db->ddirty('jsubmission', {undoStatus=>'final'}, {jsubid=>$id});
    $db->commit();
    JMAP::Telemetry::increment('smtp_unknown');
    return 'unknown';
  }
  my $attempt = sha256_hex(join(':', $$, $id, time(), rand()));
  $db->dbh->do("UPDATE jdelivery SET state='sending',owner_pid=?,attempt=?,updated=? WHERE jsubid=?",
    {}, $$, $attempt, time(), $id);
  $db->commit();
  my $envelope = JSON::XS::decode_json($row->{envelope});
  # Do not store provider diagnostics, which may contain recipients or secrets.
  my $ok = eval { $db->backend_cmd('send_email', $message, JMAP::ImapDB::_smtp_envelope($envelope)); 1 };
  my $state = $ok ? 'confirmed' : 'unknown';
  $db->begin();
  $db->dbh->do("UPDATE jdelivery SET state=?,error_code=?,updated=?
    WHERE jsubid=? AND attempt=?", {}, $state, $ok ? undef : 'smtp_outcome_unknown', time(), $id, $attempt);
  # 'final' closes the undo window; it is not a claim of recipient delivery.
  # In particular an older sender must not rediscover this as a pending retry.
  $db->ddirty('jsubmission', {undoStatus=>'final'}, {jsubid=>$id});
  $db->commit();
  JMAP::Telemetry::increment('smtp_unknown') unless $ok;
  # Retain the prepared payload even after confirmation until a separately
  # reviewed retention policy exists. Recovery never needs to redownload it.
  return $state;
}

sub recover {
  my ($class, $db) = @_;
  $db->begin();
  my $rows = $db->dbh->selectall_arrayref(
    "SELECT jsubid,owner_pid FROM jdelivery WHERE state='sending'", {Slice=>{}});
  my $recovered = 0;
  for my $row (@$rows) {
    my $pid = $row->{owner_pid};
    # A different worker can be sending right now. Never declare that live
    # owner's job safe to retry. PID reuse errs on retaining 'sending'.
    next if $pid && (kill(0, $pid) || $! == EPERM);
    $db->dbh->do("UPDATE jdelivery SET state='unknown',error_code='worker_lost',updated=? WHERE jsubid=? AND state='sending'",
      {}, time(), $row->{jsubid});
    $db->ddirty('jsubmission', {undoStatus=>'final'}, {jsubid=>$row->{jsubid}});
    $recovered++;
  }
  $db->commit();
  return $recovered;
}
sub summary {
  my ($class, $db) = @_;
  $class->recover($db);
  $db->begin();
  my $rows = $db->dbh->selectall_arrayref('SELECT state,count(*) FROM jdelivery GROUP BY state');
  $db->commit();
  return {map {$_->[0] => 0 + $_->[1]} @$rows};
}
1;
