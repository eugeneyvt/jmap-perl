# Binary Bay JMAP bridge

This is a personal compatibility fork of **jmapio/jmap-perl**, not a replacement
mail provider. Gmail/Yandex keep the original mailboxes. Upstream copyright and
MIT license are preserved. `UPSTREAM_REVISION` records the last integrated source
revision. All release source is tracked here; local patches are no longer needed
to reproduce the image.

## What this fork changes

- Installs the Text::Diff dependency needed by the upstream implementation.
- Decrypts the stored generic IMAP credential before comparing Basic credentials.
- Opt-in Gmail app-password support (`JMAP_GMAIL_APP_PASSWORD=1`); the default
  OAuth path is preserved. SMTP uses the configured transport/STARTTLS settings.
- Ignores `\\Noselect` containers when enumerating usable IMAP mailboxes.
- Runs background synchronization on a separate worker, using registered
  accounts rather than open browser workers, and prevents overlapping syncs.
- Updates `$seen`, `$flagged`, and `$answered` patches using targeted UID STORE
  and flag readback, checking UIDVALIDITY and preserving other flags/labels.
- Opt-in Suite false-to-null flag normalization (`JMAP_SUITE_FLAG_COMPAT=1`).
  Other mutations retain the upstream path.

## Images and releases

Images are published to `ghcr.io/eugeneyvt/jmap-proxy`:

| Tag | Meaning |
| --- | --- |
| `edge` | A master-branch build that passed CI; development channel |
| `stable` | Latest version-tagged release that passed CI |
| `0.1.0` (example) | A specific release; use for rollback |
| `sha-<commit>` | A specific tested source commit |

CI builds native amd64 and arm64 images, runs the repository test suite and a
network-isolated startup/authentication smoke test before publishing. External
Cyrus integration tests explicitly skip without a configured test server; CI
is not a complete Gmail/Yandex or security certification.

`Dockerfile.release` reuses a pinned upstream dependency image, then copies the
fork into a clean source directory. This avoids rebuilding the Perl dependency
stack during the initial migration and preserves its tested versions. Updating
source alone does **not** update Debian/Perl dependencies: review and refresh the
base digest for dependency/security updates, and rerun CI. The original upstream
Dockerfile is retained for full dependency rebuilds (plus Text::Diff).

For a new installation, adapt `compose.fork.example.yml`. Keep the key persistent
and private. Never publish the management API or commit real account settings,
mailbox data, environment files or credentials.

## Update an existing deployment

Once its Compose image points at `ghcr.io/eugeneyvt/jmap-proxy:stable`:

```sh
docker compose pull jmap
docker compose up -d --no-deps jmap
```

Use the existing deployment's Compose file, network, credentials and `/data`
volume. Do not replace it with the example. Back up configuration and SQLite
first. Record the current image digest/version; rollback only the code image
when rolling back a code-only update, preserving newer mailbox state.

## Bring in upstream changes

Use the **Check upstream update** GitHub Actions workflow for a read-only check:
it compares the recorded upstream revision, trial-merges and tests a candidate
when needed. It never pushes, publishes, or changes the deployed service.

To integrate an update locally:

```sh
git remote add upstream https://github.com/jmapio/jmap-perl.git # first time only
git fetch upstream master
git switch -c update-upstream
git merge upstream/master
git rev-parse upstream/master > UPSTREAM_REVISION
```

Resolve conflicts explicitly. Review dependency changes and the base digest.
Open a pull request; its checks build and test the combined source. Merging it
publishes only `edge`. After acceptance, create a version tag such as `v0.1.1`
and push it; passing release checks then publishes that version and `stable`.
Do not overwrite existing version tags.

## Acceptance limits

This fork does not yet implement usable RFC 8620 PushSubscription delivery.
Browser/mobile notification delivery through Suite remains separate work.
Calendar, contacts, Sieve and every Gmail/Yandex mutation are not certified by
the unit tests. An SMTP TLS/authentication check is not proof of end-to-end
sending. No production credentials or external test mail are used in CI.
