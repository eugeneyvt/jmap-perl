# Hybrid mail replica and local search (work in progress)

Unpublished 2026-11-04 candidate, stacked on stage2. Production is unchanged.
Do not install this branch as a completed release: full provider coverage,
UIDVALIDITY remap, migration/restore rehearsal, application integration and
operational acceptance remain required.

Original MIME files (including binary attachments) belong on guarded SSHFS
Storage Box. The SSD holds the ordinary account database, a private per-account
`replica.sqlite3` (jobs/documents/FTS5), parsed text/HTML/previews, and bounded
download cache/scratch. Raw-store access is excluded from search and Email/get
body reads. A dedicated `:content` process handles cold original/attachment
downloads; HTTP receives a validated local descriptor and emits64KiB chunks.

## Data contracts

Account schema15 adds a catalog clock with triggers for message insertion,
deactivation, deletion and identity changes. Flags alone do not invalidate
content coverage. Existing IDs/account states/credentials/outbox are retained.
The separate replica format is version1; unknown formats fail closed. WAL is
not enabled. Both databases must enter a consistent deployment checkpoint.

Jobs are identified by folder/UIDVALIDITY/UID, not Message-ID or envelope hash.
The existing JMAP ID remains a separate field. Each verified original has an
account-scoped SHA256 filename. Gmail X-GM-MSGID may reuse an already verified
label copy; generic envelope IDs cannot. Different verified contents under one
legacy JMAP ID are an explicit collision, never an overwritten document.

Queue claims carry a durable lease/token, attempts and backoff. A process loss
releases work after lease expiry. Saved raw hashes survive parsing retries;
document, FTS rows and index generation commit together. Missing sources become
tombstones; originals/documents are retained. The worker copies metadata in
bounded batches and rotates inventory across all selectable folders.

`Mail::IMAPTalk::literal_handle_control` streams EXAMINE/BODY.PEEK originals to
SSD without changing read flags or passing MIME through JSON. MIME-tools writes
binary parts to private scratch; text extraction has a16MiB budget and1000-part
limit. Budget/charset/parse errors retain verified raw and report unfinished
work. JMAP body/part IDs are checked against the independent Data::JSEmail path.

## Search modes

Default is `provider`. `shadow` returns provider results and compares complete
local hits, logging only account/query hashes and aggregate differences.
`local` requires current inventory/catalog coverage and no unresolved jobs.
New unindexed mail makes local search explicitly unavailable until caught up,
rather than returning a successful incomplete result. Index generation is part
of the SQL snapshot base and is checked around hit preparation.

Local terms use FTS5 unicode61/remove_diacritics2. Unquoted words are ANDed;
quoted phrases retain order. Fields: subject/from/to/cc/bcc/body; text also
includes attachment filenames. User FTS operators are quoted as data. Raw Gmail
search operators and arbitrary header filters are explicitly unsupported at
this point. No stemming, OCR, binary-content search or embeddings are claimed.

## Bounded worker interface

`bin/replica-worker.pl` requires an existing account and explicit raw root,
SSHFS mount, marker path and expected marker SHA256. Defaults:25 messages,
64MiB input,120 seconds,10 metadata steps per invocation. It preserves at least
1GiB SSD headroom plus four times the current raw size for parser scratch.
The supervisor must separately enforce CPU/memory/pids/spool/process deadlines:
an application alarm cannot guarantee interruption of stuck kernel FUSE I/O.

`bin/replica-control.pl --data-dir ... --account ...` is read-only status;
`--mode provider|shadow|local` changes only an existing prepared replica mode.
No mode is switched automatically by the worker. For cold downloads the bridge
requires JMAP_RAW_ROOT/MOUNT/MARKER/MARKER_SHA256, with a read-only raw mount;
the dedicated replica container receives the writeable raw mount. A marker or
mount failure prevents fallback writes to the host root filesystem.

The SSD raw cache defaults to256MiB/account and128 files. Search/parsed text
work without Storage Box. Cached originals/attachments work without it too;
uncached originals return503. Whole-message download and decoded attachments
are streamed from local files with Content-Length; disposable response scratch
is unlinked after opening. Active sockets may retain already-open cache files
after eviction, so process/admission/SSD limits still matter.

## Validation boundary

`t/replica-*.t` exercises storage integrity, mount failure, account isolation,
leases/replay/collisions/tombstones, text/HTML/attachment contracts, local search
without provider/Box, generation invalidation, schema failure recovery,
bounded cache and streamed responses. `t/bench/replica.pl` requires explicit
synthetic opt-in and its own marker/account; it measures25k/100k/250k index-only
fixtures and must not be described as original-copy completeness or production
latency. Real provider inventory, scoped Box pilot and complete recovery remain
separate acceptance gates.

Primary references: [IMAPTalk streaming API](https://github.com/robmueller/mail-imaptalk/),
[MIME-tools](https://metacpan.org/pod/MIME::Parser),
[HTTP streaming callbacks](https://metacpan.org/pod/AnyEvent::HTTPD::Request),
[FTS5](https://www.sqlite.org/fts5.html),
[SSHFS caveats](https://github.com/libfuse/sshfs/blob/master/sshfs.rst#caveats--workarounds).
