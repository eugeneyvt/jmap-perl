# Stage 1 reliability candidate — 2026-11-04

Status: local implementation and synthetic acceptance. Not a published release
and not deployed to Unit S. No provider messages or production data are used by
the new tests. This is the first stage of the Home Lab modernization plan;
SQL pagination, a full raw mirror and local search are later stages.

## Behavior

- Cache files use a private same-directory staging file, checked writes/fsync,
  atomic rename and directory fsync. New cache directories are made durable too.
  Failed pre-rename writes preserve the prior value. Corrupt parsed JSON is a
  cache miss, retained for inspection, and can be replaced after a successful
  provider read. This does not claim that every provider read will succeed.
- Account schema initialization is serialized with normal account transactions.
  DBI errors in normal transactions are exceptions. State is updated even without
  an active SSE callback. Notifications run after a successful commit; a broken
  notification connection does not turn a committed mutation into a failure.
- Per-process timing covers queue wait, DBI work without SQL text, file-lock
  wait, transaction lifetime, provider calls, SMTP, MIME parsing and cache writes.
  Parent counters survive worker exit. Linux metrics include RSS/swap by role
  and process, signal exits and cgroup OOM counters. RSS and VmSwap across forked
  workers must not be summed as if shared pages were private; use cgroup totals
  and PSS/SwapPss when diagnosing pressure.
- Admission limits count all owned live workers, including ones awaiting reap,
  pending commands and serialized payload bytes. Failed workers have bounded
  exponential respawn backoff with jitter. Backfill retries without requiring a
  whole-proxy restart; its existing needs_backfill flag remains durable.
- Read deadlines release the caller. A worker is terminated only when every
  pending command on that worker is classified as a safe read. A read queued
  behind a mutation cannot terminate the mutation. Expired reads behind writes
  keep bounded tombstones until the worker replies; there is no write replay.
  Unknown methods are conservative. IDLE keeps its separate heartbeat watchdog.
- SMTP intent and the exact held MIME are persisted before entering the
  transport. Acknowledged relay is `confirmed` in the internal journal; it is not
  proof of final recipient delivery. A dropped reply, missing/corrupt payload,
  or lost sending owner becomes `unknown` and is not retried by send_due.
  An unresolved fingerprint blocks a repeated create using the same email,
  envelope, identity and bytes. This is not universal SMTP exactly-once delivery:
  a new deliberate submission after confirmed relay is still allowed.

Transport failures are conservatively unknown because the current SMTP library
does not expose a durable per-attempt DATA acknowledgement boundary. They can
require operator review even if the network failed before acceptance. No new
automatic resend or external reconciliation is enabled. Payloads/journal rows
are retained; no new retention cleanup is included.

## Observability contract

`/healthz` remains liveness, including for Docker's current healthcheck.
`/readyz` is a new endpoint on the existing private management listener:

- 200 only when discovered local accounts have recent successful synchronization,
  no old queued command, no repeated worker failures and no known uncertain send;
- 503 for stale/unknown disk capacity, low disk space, a recent observed OOM kill,
  or the account conditions above;
- account keys are hashes, without login addresses; index status is explicitly
  `not_configured` until a later stage implements an index;
- cgroup OOM detection degrades readiness for 300 seconds after a new kill.

No monitoring service, proxy, public port, restart supervisor or alert delivery
is installed. Native JMAP failures still use method-level errors; an HTTP 200
alone is not evidence that an Email/query succeeded. Monotonic metrics include
`jmap_backend_requests_total`, operation count/sum/max, rejection/timeouts and
worker exit counters. Account IDs in the existing sync-age metric are now hashed;
review any consumers of the previous label values before rollout.

## Limits (candidate defaults)

| Environment | Default | Meaning |
| --- | ---: | --- |
| JMAP_MAX_WORKERS | 16 | Owned live worker processes, including accounts and IDLE |
| JMAP_MAX_PENDING_PER_WORKER | 4 | Pending commands, including expired-read tombstones |
| JMAP_MAX_PENDING | 64 | Pending commands across the proxy |
| JMAP_MAX_PENDING_BYTES | 32000000 | Aggregate serialized argument byte budget |
| JMAP_READ_DEADLINE | 60 | Safe-read caller deadline, seconds |
| JMAP_BACKGROUND_DEADLINE | 180 | Safe sync/backfill/davsync deadline, seconds |
| JMAP_READY_SYNC_AGE | 120 | Maximum age of successful account sync, seconds |
| JMAP_READY_REQUEST_AGE | 120 | Maximum age of a pending command for readiness |
| JMAP_MIN_FREE_BYTES | 1073741824 | Readiness disk reserve, bytes |

`JMAP_HOST` selects the public JMAP bind address (default 0.0.0.0, unchanged).
Synthetic tests bind 127.0.0.1. Management binding is unchanged. Limits require
tuning against actual load; they deliberately reject excess work instead of
retaining an unlimited queue. Resource changes on Unit S are not part of this
local implementation.

## Schema v13 and rollout gate

This candidate adds `jdelivery` and its indexes and changes user_version 12→13.
Existing IDs, folders, provider messages and credentials are not replaced.
Pending v12 submissions have no attempt journal: migration retains their bytes,
records `legacy_pending/unknown`, closes their undo window and advances the
EmailSubmission state so clients can discover the change. They require review;
neither a successful migration nor `undoStatus=final` proves delivery.

The existing bridge image-only deploy controller requires unchanged schema and
must not be used unchanged. Before any live deployment:

1. Freeze reviewed sources, run both target image tests and isolated auth/SSE
   acceptance, and publish an immutable candidate via the normal fork workflow.
2. Inspect live pending/sending submissions and resource headroom read-only.
   Rehearse v12→v13 on a separately authorized consistent disposable copy.
3. Agree the exact bridge-only interruption, resource budget, checkpoint and
   rollback. Preserve newer mail and the current deployment recipe.
4. Account for `sending/unknown` and still-held `prepared` jobs before any image
   downgrade: an older sender does not honor the journal. Do not blindly run the
   v0.2.3 rollback over newly active pending submissions.
5. Run storage/journal audits and actual account readiness after rollout. A
   liveness-only result is insufficient. No production switch is automated here.

Conservative resource proposal after the 2026-11-04 observation: 1 GiB RAM,
1.5 GiB combined RAM+swap, CPU still 0.5, with a fresh host-headroom check.
It is a mitigation candidate, not a demonstrated fix for the original growth.
The production observation showed continuing child OOM kills without new search
requests; the precise allocation/retention cause remains unproven. The new
telemetry is intended to separate those causes after an authorized rollout.

## Storage audit and recovery

`perl bin/check-mail-cache.pl --data-dir /explicit/path --account ACCOUNT`
opens SQLite read-only and never instantiates the migrating JMAP::DB constructor.
It reports aggregate parsed/catalog inconsistencies, staged/orphan files and
outbox payload hashes. It neither removes files nor advances synchronization.
JSON decoding has a configurable 16 MiB per-file memory budget; over-budget
files are reported as unverified, not silently accepted. Legacy parsed cache has
presence metadata, not immutable hashes. A full raw mirror does not yet exist.

Interrupted atomic files remain isolated staging files. Corrupt parsed content
can be reread through the normal cache-miss path. A lost SMTP worker is recovered
to unknown when the journal is inspected by a successful account command or
send_due; live owners are not disturbed. Review unknown outcomes against the
provider before a separately approved resolution. No tool here resends mail.

## Acceptance

New tests cover concurrent cache reads and injected durable-write failure,
independent-connection visibility after commit, commit and notification failure,
cache and outbox audit, schema migration and preservation of held bytes,
uncertain delivery/no retry, cancel/worker loss, fixed-label metrics, readiness,
admission/backoff and real HTTP deadlines including a write queued with a read.
A real loopback SMTP fixture receives DATA and drops its acknowledgement.
Integration tests requiring Cyrus remain explicitly skipped without that server.

Home Lab keeps the concrete image/source hashes, native/Linux results and
isolated cgroup OOM acceptance in `docs/jmap-stage1-2026-11-04/` outside this fork.
Those checks prove candidate behavior with synthetic data, not long-term live
stability, provider completeness, delivered external mail or a full local index.
