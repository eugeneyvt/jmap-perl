# Changelog

## 0.2.2 — 2026-10-31

- Preserve the cached folder list when IMAP NAMESPACE/LIST fails, returns
  malformed rows, or produces an empty snapshot for an existing account.
  A transient provider disconnect no longer hides Inbox and other folders.
- Speed up common mailbox queries sorted by receivedAt, including unread and
  keyword filters, using SQLite's existing mailbox-membership index and sort.
  Keep thread collapsing, stable tie-breaking, pagination, anchors and complete
  query-state caches compatible with the general query path. General search,
  thread-wide predicates and other sorts retain that path.
- Add 82 regression assertions for folder-read failures and mailbox queries.
  The complete offline suite passes 1,541 assertions. Provider integration tests
  remain conditional on a separately configured test server.

No database migration, new dependency or Suite source change is required.
The disposable-cache benchmark reports about 4.4x faster Gmail Email/query
responses with byte-identical results; this is not an end-to-end browser
latency guarantee.
