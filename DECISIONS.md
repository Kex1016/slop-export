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
