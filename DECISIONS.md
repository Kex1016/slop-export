# DECISIONS

Agents record every non-obvious choice here instead of stopping to ask David. Newest entry at the top. Never edit an old entry; if a decision changes, add a new entry that supersedes it and link back.

David can overrule any entry by saying so in the project. The agent then adds a superseding entry and changes the code.

## Entry format

```
### D-NNN: <short title>
- Date: YYYY-MM-DD
- Status: accepted | superseded by D-NNN | reverted
- Phase: <PLAN.md phase>
- Context: why a choice was needed, in one or two sentences.
- Options: what was considered.
- Decision: what was chosen.
- Why: the reason, with evidence (a test, a doc link, a measurement).
- Reversible: yes/no, and what it would take to undo.
- PR: <link>
```

## Entries

### D-015: Trim pasted credentials and explain a refused login
- Date: 2026-11-04
- Status: accepted
- Phase: 1 (follow-up to David's first real connect)
- Context: David's first connect to his real Bridge was refused as wrong credentials, though he pasted the Bridge user name and Bridge-generated password.
- Options: leave input as typed; trim whitespace and line breaks at login.
- Decision: `IMAPClient.login` trims leading and trailing whitespace and line breaks from the user name and password. This covers the app, the CLI and Keychain items saved earlier. A NO to LOGIN becomes `IMAPError.loginRejected`, which shows the server's own words and says which Bridge credentials to use, including split address mode.
- Why: neither Bridge credentials nor iCloud app-specific passwords can start or end with whitespace, and copying from Bridge or a password manager can add some. This is not yet confirmed as David's cause; the clearer error will show it on the next try. Tested by `testPastedWhitespaceAroundCredentialsIsIgnored`.
- Reversible: yes.
- PR: (login fix PR)

### D-014: Phase 7 review outcomes and what was left as is
- Date: 2026-11-02
- Status: accepted
- Phase: 7
- Context: Phase 7 ran security-review over the whole codebase, code-review (high) over Sources and App, simplify, and an accessibility pass. Some suggestions were not taken and need a record.
- Options: fix everything; fix what has a concrete effect and log the rest.
- Decision: fixed in Phase 7:
  - Each step keeps its own last error. It is shown in one bar under that step, with an icon labelled for VoiceOver, and announced when it appears. So a failed export still says why when you come back, and never shows up on another step.
  - Every step has a keyboard shortcut (Command-1 to Command-5) in a Go menu with a checkmark on the current step.
  - Spinners are labelled or hidden from VoiceOver.
  - Everything the CLI prints goes through `TerminalText.safe`, which strips control characters from server-supplied text. Saved reports keep the exact text.
  - A dropped Status/X-Status header also drops its folded lines.

  Left as is:
  - Keychain items set `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, which the file-based login keychain ignores. Moving to the data-protection keychain needs a keychain-access-groups entitlement that an ad-hoc signed app may not get. Revisit with Developer ID signing.
  - GitHub Actions are pinned by tag, not commit SHA. This agent session could not read the action repositories to resolve SHAs.
  - All Mail matching by Message-ID + size (D-009) could in theory let a crafted message stand in for an All Mail-only one in Unfiled. That needs the exact Message-ID and size of a message the attacker never received.
  - Switching steps from the menu while a file picker or confirmation is open closes it. This is standard SwiftUI behaviour and harmless.
- Why: each fix has a test or a visible effect. The items left as is are either blocked on signing or theoretical.
- Reversible: yes.
- PR: (Phase 7 PR)

### D-013: When upload stops instead of skipping a message
- Date: 2026-11-02
- Status: accepted
- Phase: 5
- Context: code review found that any NO to an APPEND was treated as "iCloud refuses this message", so throttling or a full mailbox would have copied every remaining message to `Not uploaded/`.
- Options: treat every NO as per-message; treat every NO as fatal; per-message only while other messages still get through.
- Decision: a refused APPEND is held back. It becomes a real refusal (copied to `Not uploaded/`, journalled) only once a later message is accepted. Three refusals in a row, or any refusal mentioning quota, stops the upload with a clear message and marks nothing as failed, so the next run retries them. APPENDs are spaced 50 ms apart, and their timeout grows with message size (32 KB/s floor) because the server is silent while a large message streams. After a dropped connection, a message counts as landed only if its folder holds more copies than the run has already accounted for.
- Why: a genuinely oversized message is still skipped and kept, while a server-wide refusal cannot quietly drop the rest of the export.
- Reversible: yes, `Uploader.Options`.
- PR: (Phase 5-6 PR)

### D-012: How verify counts and compares
- Date: 2026-11-02
- Status: accepted
- Phase: 6
- Context: verify must compare Bridge, the export, the Apple Mail folders and iCloud per folder and list every missing or extra message, without downloading mail again.
- Options: count only; compare by hash (needs every iCloud body); compare by the same Message-ID + size + INTERNALDATE key the uploader uses.
- Decision: Bridge side compares live STATUS counts (or the last scan's counts when Bridge is not connected) with what the journal recorded, per mailbox, and checks that every All Mail entry is in the store. Apple Mail side counts the `From ` separators in each bundle. `mbox` now writes `mbox-index.json` into the export folder (not the import folder Apple Mail reads) so verify knows exactly which bundles hold which folder after collision renames and size splits; without the index it falls back to matching bundle names. iCloud side reads headers only and matches each expected message with the uploader's presence key as a multiset; anything left over on either side is reported as missing or extra. Mail iCloud refused (kept in `Not uploaded/`) shows as missing, on purpose. The app shows the same report with a Swift Charts bar chart and a table, and saves HTML (everything escaped) or plain text.
- Why: no body downloads, so verify of a large account takes minutes; the key is the one upload already relies on, so verify and upload cannot disagree. Tested in `VerifyIntegrationTests` (passing case, missing uploads, emptied mbox).
- Reversible: yes, verify is read-only and self-contained.
- PR: (Phase 5-6 PR)

### D-011: How upload avoids duplicates and handles refusals
- Date: 2026-11-02
- Status: accepted
- Phase: 5
- Context: PLAN.md asks for "skip messages already present (by Message-ID + hash)", but iCloud cannot tell us a stored message's hash without downloading it.
- Options: trust a local upload journal only; download every iCloud message and hash it; journal plus a cheap check of what each folder holds.
- Decision: every successful APPEND is journalled in `upload.jsonl` (target folder + hash). Before uploading into a folder, the uploader also reads that folder's Message-ID, size and INTERNALDATE (headers only) and treats a matching message as already there, as a multiset so N identical messages need N copies. After a dropped connection mid-APPEND it checks again before resending. A message iCloud refuses (for example, over its size limit) is copied to `Not uploaded/<folder>/` in the export folder, journalled, and skipped. Empty folders are created too, so the structure matches. Upload is a dry run unless `--write` is given (CLI) or confirmed in a dialog (app), and it checks the iCloud quota before writing anything.
- Why: covers the crash window between APPEND and journal write without downloading the mailbox back. Tested by deleting `upload.jsonl` after a full upload: the re-run adds nothing.
- Reversible: yes.
- PR: (Phase 5 PR)

### D-010: Apple Mail output format
- Date: 2026-11-02
- Status: accepted
- Phase: 4
- Context: PLAN.md Phase 4 needs `.mbox` bundles Apple Mail can import, with flags and dates kept, split if too big.
- Options: one flat `mbox` file per folder; Apple Mail's own bundle layout (`Name.mbox/mbox`, subfolders nested inside the parent bundle).
- Decision: Apple Mail's bundle layout. mboxrd escaping, LF line endings, messages ordered by INTERNALDATE, `From slop-export@localhost <asctime UTC>` separators, `Status: RO` for read and `X-Status` with `A`/`F`/`T` for answered/flagged/draft (any existing Status headers are replaced). Mailboxes over 1 GiB split into `Name (2).mbox`, etc. Folder names are sanitised so they cannot escape the output folder (`..`, `/`, leading dots).
- Why: matches what Mail itself exports, so `File > Import Mailboxes > Apple Mail` takes the whole tree at once. 1 GiB is a conservative guess at where Mail's importer gets slow; to be revisited after MT-004.
- Reversible: yes; the mbox output is rebuilt from the store each time.
- PR: (Phase 3-4 PR)

### D-009: Match All Mail and Starred by Message-ID and size instead of downloading twice
- Date: 2026-11-02
- Status: accepted
- Phase: 3
- Context: Every message is in a real folder and again in Bridge's All Mail (and Starred). Downloading All Mail in full would double the download, and Bridge is slow.
- Options: download everything and dedupe by hash; fetch only Message-ID and size for All Mail and Starred, and download just the ones that match nothing.
- Decision: real folders are downloaded first. All Mail and Starred are then fetched as metadata plus the Message-ID header, and each entry is matched to a stored message with the same Message-ID and size. A stored message can stand for as many entries as it has real-folder copies, so two identical messages are never merged. Anything that does not match, including every message without a Message-ID, is downloaded and hashed. All Mail-only messages become `Unfiled`.
- Why: on the fixture this downloads 13 bodies for 12 All Mail messages instead of 25. Bridge serves the same Proton message in each mailbox, so Message-ID plus size identifies it. `verify` (Phase 6) re-checks counts per folder.
- Reversible: yes; drop the match and every All Mail entry is downloaded.
- PR: (Phase 3-4 PR)

### D-008: Keep the Bridge certificate's bytes, not a bookmark to the file
- Date: 2026-11-02
- Status: accepted
- Phase: 1
- Context: The sandboxed app needs the Bridge certificate on every launch. A file chosen in an open panel is only readable through a security-scoped bookmark.
- Options: security-scoped bookmark to the `.pem`; copy the certificate's DER bytes into the app's preferences.
- Decision: copy the DER bytes (and show their SHA-256 fingerprint). Export folders will still use bookmarks.
- Why: a certificate is public, tiny and never changes until Bridge regenerates it. Keeping the bytes means no stale-bookmark failures and nothing to re-grant.
- Reversible: yes; switch `AppModel.certificateDER` to a bookmark.
- PR: (Phase 0-2 PR)

### D-007: Custom folders named like system folders go under `Proton Folders/`
- Date: 2026-11-02
- Status: accepted
- Phase: 1, 3
- Context: Bridge lists custom folders as `Folders/<name>`; mapping them to top-level iCloud folders means a custom folder called `Archive`, `Junk` or `INBOX` would merge into the system folder of that name.
- Options: always nest custom folders under a parent; nest only the colliding ones; merge.
- Decision: custom folders become top-level iCloud folders with their nesting kept (`Folders/Work/Projects` -> `Work/Projects`), except ones whose top-level name is an iCloud system name or `Unfiled`, which go under `Proton Folders/`.
- Why: matches David's current structure for the common case and never merges two folders. Tested in `MailboxPlanTests`.
- Reversible: yes, before the first upload; it is one function, `MailboxPlan.folderTarget`.
- PR: (Phase 0-2 PR)

### D-006: Fixture servers are Dovecot processes, not Docker containers
- Date: 2026-11-02
- Status: accepted
- Phase: 2
- Context: PLAN.md suggested Dovecot or GreenMail in Docker. Docker Hub rate-limited image pulls in the agent environment, and CI already runs the Linux job inside a `swift` container where nested Docker is awkward.
- Options: Docker Compose with Dovecot/GreenMail; Dovecot installed from apt and started as a plain process; a hand-written fake IMAP server.
- Decision: `Fixtures/slopfixture.py up --dir DIR` writes a Dovecot config, a self-signed certificate and a Maildir seeded straight from Python, then starts Dovecot. Two kinds: `bridge` (STARTTLS, Bridge's mailbox layout, Bridge-like capability list without `STATUS=SIZE`/`QUOTA`) and `icloud` (implicit TLS, Apple's folder names, empty, with a quota). Bridge's virtual `All Mail` and `Starred` are seeded as real mailboxes holding copies, which is what a client sees.
- Why: needs only `apt-get install dovecot-imapd`, starts in about a second, and works the same on an agent box and in CI. A real IMAP server catches protocol mistakes a fake would not.
- Reversible: yes; the tests only read `DIR/<kind>.json`.
- PR: (Phase 0-2 PR)

### D-005: XcodeGen for the app project
- Date: 2026-11-02
- Status: accepted
- Phase: 0
- Context: PLAN.md asked for XcodeGen or Tuist.
- Options: XcodeGen; Tuist; a checked-in `.xcodeproj`.
- Decision: XcodeGen, spec in `App/project.yml`. The `.xcodeproj` is generated in CI and ignored by git.
- Why: one YAML file, a single `brew install`, no extra runtime or manifests in Swift. The app is one target plus UI tests, which is XcodeGen's sweet spot.
- Reversible: yes; Tuist can import the same structure.
- PR: (Phase 0-2 PR)

### D-004: Pin Bridge's exact certificate
- Date: 2026-11-02
- Status: accepted
- Phase: 1
- Context: Bridge serves a self-signed certificate for 127.0.0.1. Turning verification off is ruled out by PLAN.md and AUTOPILOT.md.
- Options: trust the exported cert as a CA and skip the hostname check; compare the server's leaf certificate byte for byte with the exported one.
- Decision: byte-for-byte pin. The TLS handshake only succeeds if the server's leaf certificate's DER equals the one David exported. The app shows its SHA-256 fingerprint. iCloud uses the normal system trust store and hostname check.
- Why: strictest option, and simple. Covered by `testWrongCertificateIsRejected`, which connects to the Bridge fixture with the iCloud fixture's certificate and must fail.
- Reversible: yes. If Bridge regenerates its certificate, David exports it again.
- PR: (Phase 0-2 PR)

### D-003: swift-nio-imap 0.4.0 with a small client on top
- Date: 2026-11-02
- Status: accepted
- Phase: 0, 1
- Context: D-002 picked `swift-nio-imap`. Its `main` branch needs Swift 6.2 and macOS 15; the plan targets macOS 14. The library is a parser and encoder, not a client.
- Options: track `main` and raise the minimum to macOS 15; pin 0.4.0 (Swift 6.0, no platform floor); MailCore2.
- Decision: pin `exact: "0.4.0"` and write `IMAPClient` (an actor, one command at a time, no pipelining) plus `ResponseCollector` (matches tagged responses, assembles streamed FETCH bodies). NIOSSL for TLS on both platforms.
- Why: keeps macOS 14 support. 0.4.0 already handles literals, continuations, APPEND streaming and modified UTF-7. One command at a time is plenty for Bridge, which is slow anyway, and keeps resume logic simple. It worked first time against Dovecot.
- Reversible: yes; the client is about 300 lines behind a small API.
- PR: (Phase 0-2 PR)

### D-002: slop-export is a native macOS app
- Date: 2026-11-02
- Status: accepted
- Phase: all; replaces the Python CLI default in PLAN Phase 0
- Context: David said the tool must be a macOS application and called it crucial.
- Options: Swift and SwiftUI native app; SwiftUI shell around a Python core; Electron or Tauri wrapper; CLI only.
- Decision: Swift 6 and SwiftUI app on macOS 14+, with all logic in a `SlopCore` Swift package shared by the app and a `slop-export` CLI. IMAP via `swift-nio-imap`, MailCore2 as fallback. Keychain for secrets, App Sandbox on. CI builds on Linux (core, integration tests against Docker fixtures) and `macos-15` (app, UI tests, packaging). Ad-hoc signed by default; Developer ID and notarization if David has an Apple Developer account.
- Why: David asked for it. A native app gets the Keychain, sandbox and a normal Mac install with no runtime to bundle. A Python core would need a bundled interpreter and complicates signing; Electron adds a large runtime for a single-window tool. The CLI and a Linux-buildable core let agents test unattended without a Mac.
- Reversible: partly. The core and CLI survive a UI change; switching languages would mean a rewrite, so choose before Phase 0 code lands.
- PR: (this PR)

### D-001: Drop labels
- Date: 2026-11-02
- Status: accepted
- Phase: 3, 4, 5
- Context: iCloud has no labels. The draft plan copied each labelled message into a `Labels/<name>` folder.
- Options: copy into label folders; keep one copy and write labels to an `X-Keywords` header; drop labels.
- Decision: drop labels. Skip Bridge's `Labels/*` mailboxes and create no label folders. Messages that are only in `All Mail` still go to `Unfiled`.
- Why: David asked for it in the project thread on 2026-11-02. It also avoids duplicates and saves iCloud space.
- Reversible: yes. Teach export to read `Labels/*` and re-run it; the store is resumable, so nothing already exported is fetched again.
- PR: https://github.com/Kex1016/slop-export/pull/1
