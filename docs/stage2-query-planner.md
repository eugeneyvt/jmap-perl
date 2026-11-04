# Stage 2: SQL mail queries and durable list summaries

Unpublished candidate, 2026-11-04. Stacked on the stage-1 reliability candidate;
neither candidate is installed in the personal Unit S deployment. This changes
the account schema **13→14** (production remains v12). It does not implement a
full MIME replica, FTS, embeddings, provider completeness, or a live migration.

## Query execution

`JMAP::QueryPlanner` compiles current Email filters and comparators into bound
SQLite predicates. Mailbox/date/size/keyword/attachment predicates stay in SQL.
AND, OR and NOT retain the complete active-message universe. Thread predicates
and thread keyword sorts inspect the whole conversation, including other
mailboxes and messages outside the provider hits. String sorting uses the same
three `JMAP::Collation` algorithms as the reference implementation.

The first query for a metadata/content generation creates ordered snapshot rows
with SQL window functions. Filtering and representative selection occur before
page selection. The representative is the first matching email in the requested
order, with the existing string-ID tie break. Later pages read only their IDs;
they do not build full Perl metadata/ID arrays or rewrite a JSON snapshot.
Negative positions, anchors, anchor offsets, empty pages and zero limits retain
their specified behavior. `total` counts representatives when collapsed and is
only returned when requested. The row count already recorded during snapshot
construction avoids an extra full count on each page.

`JMAP::QueryStore` uses account, authorized scope (currently the whole authorized
account), resolved creation references, normalized parameters, Email/Mailbox
state and search generation. Provider results add a digest of their matched IDs.
Opaque `q2.` tokens deliberately differ from the old numeric query states.
`advance_search_generation` is the storage hook for new searchable content;
attachment discovery already uses it. No index is claimed to exist yet.

Rows and their advertised state are read in one transaction. Provider I/O occurs
between transactions; a racing catalog generation causes a bounded retry, never
a snapshot labeled with a stale state. QueryChanges compares snapshots in SQL.
Changed mutable objects are removed/reinserted, including representatives whose
siblings changed a thread-wide predicate. A purge floor, expired/missing state
or a token from another account/scope returns `cannotCalculateChanges`.
`maxChanges` is checked before returning a partial diff. Immutable `upToId` is
not used as an optimization: returning the full exact diff is permitted.

## Provider search

Text/header/address searches still run at the provider. The adapter obtains UID
hits first and maps them with batched temporary UID tables and indexed joins,
not one metadata lookup per UID. A logically necessary positive provider term
can drive the candidate join. OR intersects such necessities and NOT never
narrows the universe, so local alternatives and thread siblings cannot disappear.
Repeated identical leaves share one provider search.

The current Gmail x-gm-raw language and All Mail/Trash scope are preserved,
including their existing completeness limits. Malformed responses and changed
UIDVALIDITY fail instead of being cached as partial/empty results. No blind
network mutation replay is added.

Provider snapshots have an explicit **10-second freshness window** by default,
also invalidated by local metadata/folder generations. This is bounded stale
search caching, not a guarantee of instantaneous external-provider visibility.
Refreshing identical hits safely renews the existing immutable result; changed
hits change queryState even if local metadata has not changed.

## Cache and database bounds

| Environment | Default | Meaning |
| --- | ---: | --- |
| JMAP_QUERY_TTL | 3600 | Snapshot validity in seconds |
| JMAP_QUERY_MAX_ROWS | 250000 | Aggregate persistent snapshot rows per account |
| JMAP_QUERY_MAX_BYTES | 67108864 | Conservative accounted bytes, including both row indexes |
| JMAP_QUERY_MAX_SNAPSHOTS | 64 | Persistent snapshots per account |
| JMAP_PROVIDER_QUERY_TTL | 10 | Provider-hit freshness in seconds |
| JMAP_SQLITE_BUSY_TIMEOUT_MS | 5000 | Unexpected SQLite writer wait; maximum 30000 |

Expiry/eviction runs on materialization. Reads do not rewrite cache age. Eviction
orders by last materialization/confirmation; this is not a per-read LRU. Lowered
budgets also apply to existing cached queries. An oversized result uses a file-
backed temporary snapshot: the requested IDs/total remain correct, while
`canCalculateChanges=false` honestly disables persistent diffs. These bounds
cover live cache records, not SQLite's retained free pages or a raw disk quota.

Each worker reuses its own configured connection, never a connection inherited
across fork. Read transactions use shared account locks, deferred BEGIN and
SQLite `query_only`; writes retain the exclusive account lock and short normal
transactions. Failed operations discard the connection for recovery. The
coarse writer lock is retained. No WAL, dependency upgrade, service restart or
resource-limit change is introduced.

Indexes cover active receivedAt ordering in both directions with ascending ID
ties, active membership/thread lookup and changed-modseq lookup. Concrete query
plans and measurements belong in the Home Lab stage-2 evidence. A new state
still scans/builds SQL rows: cold materialization can be slower than one legacy
small/large-folder request, while subsequent pages reuse that work. Do not
describe the synthetic transport timings as Gmail/Yandex network latency.

## Email/get and Suite

Metadata, mailbox memberships and thread rows are fetched in bounded IN batches.
`jemailsummary` retains preview, list header properties and attachment **metadata**
when parsed content becomes available. These survive parsed-file eviction or
corruption. A repeated unchanged parsed-cache hit does not rewrite summaries.
Body/header/body-structure requests continue through the full-content path;
new content without any local summary can still require its first provider
download. This is not a full offline mailbox.

Native Suite currently requests full bodies even for list cache misses. A
separately prepared Suite delta requests summary properties for mailbox/search
lists, keeps summaries out of its full-message cache, and fetches a complete
thread before the reader/composer consumes it. It preserves address indexing,
account ownership checks, background replies and unsaved drafts. This companion
change requires its own application release; it is not part of this bridge image.

## Validation and rollout

Tests compare SQL results against the independent legacy Perl path over 240
filter/sort/collapse/page combinations, and cover provider boolean logic,
state races, UIDVALIDITY, cache freshness/bounds, SQL diffs, shared readers,
concurrent writers/modseq, busy errors, metadata batching and summary eviction.
The v13→v14 test preserves IDs, account states, encrypted settings, held bytes
and SMTP journal; injected DDL failure rolls back and a clean retry succeeds.
`t/bench/query.pl` is an explicitly opted-in, synthetic-only offline benchmark.
Cyrus integrations remain explicitly skipped without their test server.

Before a production switch, publish/review immutable images, prepare a new Suite
release rather than editing its frozen accepted recipe, rehearse complete cache
checkpoint/restore and active-send handling, obtain the separately agreed
bridge/application interruption, and verify actual account behavior afterwards.
The old unchanged-schema deployment controller is still insufficient. Preserve
newer mail on rollback; never restore an old database over live user activity.
