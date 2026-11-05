# Unit S mail runtime acceptance, 2026-11-05

Runtime code854b1f952cc5a3fa20e6b98ac285c208d5b283e7 is installed with Suite
2026.11.05.mail4. Bridge image:
`sha256:ebc61d0527daf8439462771fd62dc99108848a0037e339de9c6b2322feba871b`.
Suite image:
`sha256:708b2249a24feb56d99641fe0da105573d86004d758a77790e8c268060542378`.
The branch is pushed; a newly published stable release or a successful GitHub
CI run for these commits is not claimed here.

The reported failure combined delayed flags/list movement and a provider
search failing after tens of seconds. The earlier single-thread toggle test
missed the different-row case. Mail4 batches adjacent equal pending flag writes,
protects optimistic intent against stale list replies, waits for writes before
coalesced refreshes, and anchors the actually visible DOM row. Python app source
and database schema are unchanged from Suite mail3; theme adaptation remains.

A real four-row test also exposed Gmail's omitted implicit selected-folder
label: a UID was freshly returned from Inbox with empty X-GM-LABELS while its
All Mail copy explicitly named Inbox.3361e81 preserves that observed membership
without unioning old cached copies. The former regression failed3/7 cases;
the new implementation passes7/7, including a later authoritative archive.
Fifteen affected local projections were independently confirmed at the provider
and reconciled with read-only point FETCH. No provider writes, UID checkpoint
advance or original deletion occurred. Remaining Inbox projection mismatches0.

854b1f9 bounds each safe search attempt to8 seconds and allows one reconnect
only on transport timeout/closure. Blocking TLS in IMAPTalk bypasses its select
read timeout; the scoped alarm covers login/EXAMINE/SEARCH/UNSELECT and preserves
an earlier external deadline.13 tests exercise real blocked sockets, successful
reconnection, persistent blocking, absence of leaked alarms and outer deadlines.
No write retry or provider-NO retry is added. The whole native suite75files/
2447 assertions and target AMD6475/2459 pass. Live provider timing is still
variable; the final UI probes are observations, not a service-level guarantee.

Suite's isolated checkpoint restored and SHA-verified1439files/2085817053bytes;
migrate/schema/source/HTTP passed, reviewed_source_delta=[], no outbound network
or background workers. Installation used a consistent encrypted checkpoint,
1446files/2122211226bytes, and took324.75s with270.16s maintenance. It did not
restore or migrate production databases. Two existing immutable recovery-image
archives remain verified external references instead of being duplicated in
every checkpoint. Only the separately approved old builder cache was pruned;
Engine images, runtime/user data and recovery archives remained. Other disk
cleanup is a separate operation and is not attributed to this approval.

Final real mouse test: eight native row-button actions over four DIFFERENT
threads in two accounts,5.565s, dots update after each click; all four positions
are identical before/after and after replies settle. All original final flags
are independently read back, SMTP sends0. Browser semantic clicks had their own
auto-scroll; coordinate clicks excluded that test artifact. Native merged list
20threads/55,068bytes/0.520s contains no full bodies; list and full-reader paths
pass for both accounts. After the final bridge update Suite/Mail/Drive return200,
bridge/event relay are healthy, OOM and automatic restarts0.

A fresh palette with all accounts enabled, Command K and no Enter returned:

| Query | Observed end-to-end time | Visible mail results |
| --- | --- | --- |
| wildberries |5.123s |6 |
| github |8.520s |10 plus See all |

Both started at zero options with Searching and ended without a search error.
This excludes a memoized answer from the previous palette, not provider/server
caching. Earlier intermittent failures are retained in private incident records;
one successful request alone was not treated as proof of a complete repair.

Full acquisition continues in an isolated cohort on Unit S, independently of
the Mac. At02:43UTC Gmail had14829 complete UID jobs/28755 remaining and6949
parser2 documents; these are not unique-original counts. Yandex had28 completed
jobs but incomplete inventory due to a historical provider gap. Production stays
in provider mode, with no raw replica mount or automatic promotion. A bounded
server supervisor retains its original deadline/resume counter; local Codex
heartbeat is paused. Full raw coverage, independent restore and local search
are still pending. A checkpoint on the content Storage Box is not independent
backup evidence; new image/full-raw inclusion in a WD snapshot is not verified.

Current and previous Docker images remain. Search-deadline code can revert to
schema15 image96eabee8, retaining the Gmail membership fix and current databases.
Suite can revert to91d03582 with its previous assets mapping, preserving the
current bridge and live files/databases. Its original generic rollback record
also contains an older bridge reference: use a targeted Suite image switch
after later bridge updates. No rollback was executed during final acceptance.

The private deployment owns exact manifests/checkpoints/compose and acceptance
records. Use its current guards rather than the old schema12 recipes. Diagnostics
must load this fork from `/opt/binarybay-jmap`, not the older dependency source
that can remain at `/opt/jmap-perl` inside the pinned base image.
