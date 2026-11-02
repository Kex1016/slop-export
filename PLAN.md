# PLAN: Proton Mail to iCloud Mail exporter

## Goal

Export every message David has in Proton Mail, with all of its folders and flags, and get it into iCloud Mail so that iCloud holds the same mail in the same structure. slop-export is a native macOS application (D-002). It reads from Proton Mail Bridge on David's Mac and writes to a layout Apple Mail can import, or uploads straight to iCloud.

"Done" means all of the acceptance criteria at the bottom of this file are met and David has signed off the last entry in `MANUAL-TESTS.md`.

## Ground rules

- Read-only on the Proton side. The tool never deletes, moves or flags anything in Proton.
- Never get around Proton's or Apple's security. No scraping the web apps, no 2FA workarounds, no stored passwords in the repo. Every sign-in is David's and goes in `MANUAL-TESTS.md`.
- Real mail never enters the repo, CI logs or project files. Tests use synthetic fixtures only.
- Every non-obvious choice goes in `DECISIONS.md`. How agents work unattended is in `AUTOPILOT.md`.

## App shape (D-002)

- **Stack:** Swift 6 and SwiftUI, minimum macOS 14 (Sonoma), Apple silicon and Intel (universal build).
- **Layout:** one Swift package, `SlopCore`, holds all IMAP, store, mbox, upload and verify logic with no UI code. Two thin targets sit on top of it: `SlopExport.app` (SwiftUI) and `slop-export` (a command-line tool). The CLI exists so agents can run and test everything headless, on Linux and in CI; David uses the app.
- **IMAP:** `swift-nio-imap` (Apple's SwiftNIO IMAP library). If it proves too low-level for APPEND or IDLE-free bulk fetches, fall back to MailCore2 and record it in `DECISIONS.md`.
- **Secrets:** macOS Keychain via the Security framework, set from inside the app. The CLI reads the same Keychain items on macOS and environment variables on Linux test runs.
- **Sandbox:** App Sandbox on, with the network client entitlement and user-selected read/write file access (export folder and Bridge cert are chosen in an open panel and kept as security-scoped bookmarks).
- **App flow:** a window with five steps: Connect (Bridge host, port, cert, password) → Scan (mailbox list with counts and sizes) → Export (progress per folder, pause, resume) → Verify (Swift Charts, Proton vs export vs iCloud) → Upload (iCloud credentials, dry run, then upload). Each step shows what is left and survives quitting the app.
- **Packaging:** Xcode project generated from a checked-in spec (XcodeGen or Tuist, decided in Phase 0), built with `xcodebuild`, shipped as a zipped `.app` and a `.dmg` attached to a GitHub Release.
- **Signing:** ad-hoc signed by default, so it runs on David's Mac after a one-time "Open anyway" in System Settings. If David has an Apple Developer account, add Developer ID signing and notarization in CI (secrets stored in GitHub Actions, never in the repo).

## How the pieces fit

```
Proton servers ──(Bridge, on David's Mac)──> IMAP 127.0.0.1:1143
                                                  │
                         SlopExport.app / slop-export CLI (SlopCore)
                                                  │
                         ┌────────────────────────┼─────────────────────────┐
                         ▼                        ▼                         ▼
              Path A: .mbox bundles     manifest.json + report     Path B: IMAP APPEND
              for Apple Mail import     (counts, hashes, gaps)     to imap.mail.me.com:993
                         │                                                  │
              Apple Mail "Import Mailboxes"                                 │
              then drag into iCloud ───────────────> iCloud Mail <──────────┘
```

## What Bridge exposes (verify in Phase 1)

Bridge serves a local IMAP server (default `127.0.0.1:1143`, STARTTLS, self-signed cert) with a Bridge-generated password, not the Proton password. Expected mailboxes:

| Bridge mailbox | Meaning | Target in iCloud |
|---|---|---|
| `INBOX` | Inbox | `INBOX` |
| `Sent` | Sent | `Sent Messages` |
| `Drafts` | Drafts | `Drafts` |
| `Archive` | Archive | `Archive` |
| `Spam` | Spam | `Junk` |
| `Trash` | Trash | `Deleted Messages` |
| `Starred` | Virtual, starred messages | `\Flagged` flag, not a folder |
| `All Mail` | Virtual, every message once | Used for completeness checks |
| `Folders/<name>` | Custom folders (nested with `/`) | Matching nested folder |
| `Labels/<name>` | Labels; a message can carry many | Not exported (see D-001) |

Labels are dropped (D-001). The tool never reads the `Labels/` mailboxes and creates no label folders in iCloud. Each message goes only to the real folder it lives in.

Messages that are only in `All Mail` and in no folder (possible with some label-only messages) must still be exported, to an `Unfiled` folder, so dropping labels never drops mail.

## Phases

Each phase ends with a merged PR, its tests green, and its manual checks logged.

### Phase 0: Scaffold
- Swift package `SlopCore`, the `slop-export` CLI target (`probe | export | verify | upload`) and an empty SwiftUI `SlopExport.app` with the five-step window.
- Choose XcodeGen or Tuist for the app project and record it in `DECISIONS.md`.
- CI on GitHub Actions:
  - `linux` job (ubuntu): `swift build`, `swift test` for `SlopCore` and the CLI, plus integration tests against the Docker fixture servers (Docker is only available on Linux runners).
  - `macos` job (`macos-15`, latest Xcode): build the universal app with `xcodebuild`, run unit and UI tests, `swiftlint`, and upload the zipped `.app` as a build artifact.
  - `release` job on tags: build, sign (ad-hoc, or Developer ID plus notarization when secrets exist), and attach `.zip` and `.dmg` to a GitHub Release.
- `.gitignore` for exports, `.env`, certs, `DerivedData`, `build/`.
- Run the `init` skill to write `CLAUDE.md` once there is code.

### Phase 1: Probe Bridge
- `probe` connects to Bridge, lists every mailbox with message counts and total size, and prints Bridge's version and capabilities. It downloads nothing.
- In the app this is the Connect and Scan steps. The Bridge password is typed into a secure field and saved to the Keychain, never shown again.
- The CLI reads credentials from the Keychain on macOS and from environment variables on Linux test runs, never from arguments that land in shell history.
- Handle the self-signed cert: accept only the cert David exports from Bridge settings (pinned), not "verify off".
- Manual test: David opens the app, connects to his real Bridge and reports the mailbox list with counts (names may be redacted).

### Phase 2: Test harness without Proton
- A local IMAP server in Docker (Dovecot or GreenMail) seeded with synthetic mail that mirrors Bridge's layout: nested folders, a `Labels/` mailbox the tool must skip, starred, unread, drafts, huge attachments, non-UTF-8 headers, missing `Message-ID`, duplicates, an `All Mail`-only message.
- A second fixture server stands in for iCloud for Path B.
- All later phases are developed and tested against these, so agents never need David's account to make progress.

### Phase 3: Export engine
- Walk every mailbox except `Labels/*` (and the virtual `Starred`), fetch `RFC822`, `FLAGS`, `INTERNALDATE` with `BODY.PEEK` so nothing is marked read.
- Write a content-addressed raw store (`store/<sha256>.eml`) plus `manifest.json` that maps each message to its mailboxes, flags, date, size, `Message-ID` and hash.
- Resumable and idempotent: a crash or Bridge restart resumes from the manifest, keyed on `UIDVALIDITY` + UID.
- Throttle and retry, since Bridge syncs slowly on large accounts and can drop connections.

### Phase 4: Apple Mail layout (Path A)
- From the store and manifest, build one `<Name>.mbox/` bundle per target folder (Apple Mail's own format: directory containing an `mbox` file), nested to mirror folders.
- mboxrd escaping of `From ` lines, `Status`/`X-Status` headers for read and flagged state, original dates kept.
- Split mailboxes that pass a size limit if Apple Mail chokes on them (limit found in testing, recorded in `DECISIONS.md`).
- Manual test: David imports into Apple Mail (`File > Import Mailboxes…`), spot-checks, then drags into iCloud.

### Phase 5: Direct iCloud upload (Path B)
- The Upload step (and `upload` in the CLI) APPENDs from the store to `imap.mail.me.com:993` with an app-specific password David creates, keeping flags and `INTERNALDATE`.
- Creates folders, skips messages already present (by `Message-ID` + hash), resumable, rate-limited.
- Checks iCloud storage quota before starting and stops with a clear message if the export won't fit.
- Dry-run mode that only reports what it would do.
- Writing to iCloud is outward-facing: the first real upload needs David's go-ahead in the thread.

### Phase 6: Verify
- `verify` compares Bridge counts, the manifest, the mbox output and (for Path B) iCloud counts per folder, and lists every missing or extra message.
- The app shows per-folder charts with Swift Charts (use the `dataviz` skill for the design) and can save the report as HTML and plain text.

### Phase 7: Hardening, packaging and docs
- `security-review` skill over the full codebase: Keychain use, TLS pinning, sandbox entitlements, path traversal from folder names, header injection.
- `code-review` at high effort, then `simplify`.
- Accessibility pass on the app (VoiceOver labels, keyboard navigation, Dynamic Type where it applies).
- First tagged release with `.zip` and `.dmg`.
- README with a step-by-step for David: install the app, set up Bridge, run each step, and the iCloud checks.

## Acceptance criteria

1. Every mailbox Bridge lists, including every custom folder, is accounted for in the manifest. `Labels/*` mailboxes are listed as skipped.
2. Every message in Bridge's `All Mail` is in the store exactly once (by hash), and `verify` shows zero missing.
3. Read, starred, answered and draft state survive into iCloud.
4. Original dates show correctly in iCloud (not the import date).
5. Attachments open and non-ASCII subjects and bodies render correctly on a sample David checks.
6. Re-running export or upload after a crash adds nothing twice and skips nothing.
7. No credentials, real mail or personal data are in the repo, CI logs or project files.
8. `verify` passes against David's real account and he signs off in `MANUAL-TESTS.md`.
9. David can download the app from a GitHub Release, open it on his Mac and do the whole export and upload from the app alone, without Terminal.
10. The app runs sandboxed, keeps every password in the Keychain, and survives being quit mid-export without losing or duplicating work.

## Risks

- Bridge requires a paid Proton plan and can take hours to sync a large account before counts are stable.
- iCloud has a storage quota (5 GB on free tier) and a per-message size limit; oversized messages need a fallback (stored as `.eml` in a folder David keeps locally).
- Apple Mail import of very large mbox files can hang. Path B avoids it.
- An ad-hoc signed app needs a one-time Gatekeeper override, and macOS updates may tighten that. Developer ID signing needs a paid Apple Developer account.
- macOS CI runners cost more minutes and have no Docker, so IMAP integration tests run on Linux against the CLI.
- `swift-nio-imap` is lower-level than a full mail client library; budget time in Phase 1 to confirm it covers what the plan needs.
- Proton or Apple may change Bridge or iCloud IMAP behaviour; record the versions tested in `DECISIONS.md`.
