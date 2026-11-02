# PLAN: Proton Mail to iCloud Mail exporter

## Goal

Export every message David has in Proton Mail, with all of its folders, labels and flags, and get it into iCloud Mail so that iCloud holds the same mail in the same structure. The tool reads from Proton Mail Bridge on David's Mac and writes to a layout Apple Mail can import, or uploads straight to iCloud.

"Done" means all of the acceptance criteria at the bottom of this file are met and David has signed off the last entry in `MANUAL-TESTS.md`.

## Ground rules

- Read-only on the Proton side. The tool never deletes, moves or flags anything in Proton.
- Never get around Proton's or Apple's security. No scraping the web apps, no 2FA workarounds, no stored passwords in the repo. Every sign-in is David's and goes in `MANUAL-TESTS.md`.
- Real mail never enters the repo, CI logs or project files. Tests use synthetic fixtures only.
- Every non-obvious choice goes in `DECISIONS.md`. How agents work unattended is in `AUTOPILOT.md`.

## How the pieces fit

```
Proton servers ──(Bridge, on David's Mac)──> IMAP 127.0.0.1:1143
                                                  │
                                    slop-export  (read-only IMAP client)
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
| `Labels/<name>` | Labels; a message can carry many | See label strategy below |

Labels have no equivalent in iCloud. The default strategy is: the message lives in its real folder, and a copy goes in a `Labels/<name>` folder for each label it carries. This keeps every view David has today at the cost of duplicates. Alternatives (no copies plus an `X-Keywords` header, or one folder per label only) are recorded in `DECISIONS.md` if chosen.

Messages that are only in `All Mail` and in no folder (possible with some label-only messages) must still be exported, to an `Unfiled` folder, so nothing is lost.

## Phases

Each phase ends with a merged PR, its tests green, and its manual checks logged.

### Phase 0: Scaffold
- Pick language and packaging (default: Python 3.12, stdlib `imaplib`, `email`, `mailbox`; `uv` for packaging). Record in `DECISIONS.md`.
- CLI skeleton: `slop-export probe | export | verify | upload`.
- CI on GitHub Actions: lint, type check, tests.
- `.gitignore` for exports, `.env`, certs.
- Run the `init` skill to write `CLAUDE.md` once there is code.

### Phase 1: Probe Bridge
- `probe` connects to Bridge, lists every mailbox with message counts and total size, and prints Bridge's version and capabilities. It downloads nothing.
- Credentials come from environment variables or the macOS Keychain, never from arguments that land in shell history.
- Handle the self-signed cert: accept only the cert David exports from Bridge settings (pinned), not "verify off".
- Manual test: David runs `probe` against his real Bridge and pastes the mailbox list with counts (names may be redacted).

### Phase 2: Test harness without Proton
- A local IMAP server in Docker (Dovecot or GreenMail) seeded with synthetic mail that mirrors Bridge's layout: nested folders, labels, a message with several labels, starred, unread, drafts, huge attachments, non-UTF-8 headers, missing `Message-ID`, duplicates, an `All Mail`-only message.
- A second fixture server stands in for iCloud for Path B.
- All later phases are developed and tested against these, so agents never need David's account to make progress.

### Phase 3: Export engine
- Walk every mailbox, fetch `RFC822`, `FLAGS`, `INTERNALDATE` with `BODY.PEEK` so nothing is marked read.
- Write a content-addressed raw store (`store/<sha256>.eml`) plus `manifest.json` that maps each message to its mailboxes, flags, date, size, `Message-ID` and hash.
- Resumable and idempotent: a crash or Bridge restart resumes from the manifest, keyed on `UIDVALIDITY` + UID.
- Throttle and retry, since Bridge syncs slowly on large accounts and can drop connections.

### Phase 4: Apple Mail layout (Path A)
- From the store and manifest, build one `<Name>.mbox/` bundle per target folder (Apple Mail's own format: directory containing an `mbox` file), nested to mirror folders.
- mboxrd escaping of `From ` lines, `Status`/`X-Status` headers for read and flagged state, original dates kept.
- Split mailboxes that pass a size limit if Apple Mail chokes on them (limit found in testing, recorded in `DECISIONS.md`).
- Manual test: David imports into Apple Mail (`File > Import Mailboxes…`), spot-checks, then drags into iCloud.

### Phase 5: Direct iCloud upload (Path B)
- `upload` APPENDs from the store to `imap.mail.me.com:993` with an app-specific password David creates, keeping flags and `INTERNALDATE`.
- Creates folders, skips messages already present (by `Message-ID` + hash), resumable, rate-limited.
- Checks iCloud storage quota before starting and stops with a clear message if the export won't fit.
- Dry-run mode that only reports what it would do.
- Writing to iCloud is outward-facing: the first real upload needs David's go-ahead in the thread.

### Phase 6: Verify
- `verify` compares Bridge counts, the manifest, the mbox output and (for Path B) iCloud counts per folder, and lists every missing or extra message.
- Produces `report.html` with per-folder bar charts (use the `dataviz` skill) and a plain-text summary.

### Phase 7: Hardening and docs
- `security-review` skill over the full codebase: credential handling, TLS, path traversal from folder names, header injection.
- `code-review` at high effort, then `simplify`.
- README with a step-by-step for David, including Bridge setup and the iCloud steps.

## Acceptance criteria

1. Every mailbox Bridge lists, including every custom folder and label, is accounted for in the manifest.
2. Every message in Bridge's `All Mail` is in the store exactly once (by hash), and `verify` shows zero missing.
3. Read, starred, answered and draft state survive into iCloud.
4. Original dates show correctly in iCloud (not the import date).
5. Attachments open and non-ASCII subjects and bodies render correctly on a sample David checks.
6. Re-running export or upload after a crash adds nothing twice and skips nothing.
7. No credentials, real mail or personal data are in the repo, CI logs or project files.
8. `verify` passes against David's real account and he signs off in `MANUAL-TESTS.md`.

## Risks

- Bridge requires a paid Proton plan and can take hours to sync a large account before counts are stable.
- iCloud has a storage quota (5 GB on free tier) and a per-message size limit; oversized messages need a fallback (stored as `.eml` in a folder David keeps locally).
- Apple Mail import of very large mbox files can hang. Path B avoids it.
- Labels to folders creates duplicates and uses more iCloud space.
- Proton or Apple may change Bridge or iCloud IMAP behaviour; record the versions tested in `DECISIONS.md`.
