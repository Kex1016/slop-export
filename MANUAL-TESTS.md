# MANUAL TESTS

Steps only David can do: sign-ins, anything on his Mac or in his real accounts, and checks that need human eyes. Agents add an entry whenever they reach such a step, then keep working against the fixture servers (see `PLAN.md`, Phase 2) instead of waiting.

## Rules for agents

- Write each step so David can follow it without reading code: exact commands, exact menu paths, what he should see.
- Never ask David to paste a password, token or real message content. Ask for counts, yes/no, or redacted output.
- Group pending steps so David can do several in one sitting. Tell him in the thread when a batch is ready, once.
- When David reports a result, fill in the result fields and change the status. A failure becomes a bug the agent fixes, followed by a new entry to retest.

## Entry format

```
### MT-NNN: <short title>
- Status: pending | passed | failed | blocked | skipped
- Added: YYYY-MM-DD by <thread>
- Phase / PR: <phase>, <link>
- Why David: sign-in | his device | his account | human judgement
- Before you start: what must be running or installed.
- Steps:
  1. ...
- Expected: what he should see.
- Report back: exactly what to send (counts, yes/no, screenshot with names blurred).
- Result: (filled after David reports) date, outcome, notes.
```

## Known upcoming steps

These will become full entries when their phase starts:

- Install and sign in to Proton Mail Bridge, let it finish syncing, and export its TLS certificate.
- Download the app from the GitHub Release, move it to Applications and approve it once under System Settings > Privacy & Security > Open Anyway (ad-hoc signed builds only).
- Tell the agents whether you have an Apple Developer account, so they can add Developer ID signing and notarization (optional).
- In the app's Connect step, choose the Bridge certificate and enter the Bridge password (it goes to the Keychain), then report the mailbox names and counts from the Scan step.
- Approve the app's Keychain prompts the first time, and the folder access prompt for the export folder.
- Create an iCloud app-specific password at account.apple.com and enter it in the app's Upload step (Path B).
- Check iCloud storage has room for the export.
- Import the `.mbox` output in Apple Mail and spot-check (Path A).
- Approve and watch the first real upload to iCloud (Path B).
- Quit the app mid-export, reopen it, and confirm it resumes where it stopped.
- Final check on iPhone or iCloud.com: folders, dates, flags, attachments.

## Entries

### MT-007: Verify against your real account and sign off
- Status: pending
- Added: 2026-11-02 by "Build the Proton to iCloud exporter"
- Phase / PR: Phase 6, (Phase 5-6 PR)
- Why David: his account; acceptance criterion 8 is his sign-off
- Before you start: MT-003 passed. For the iCloud columns, MT-006 passed too. Bridge running.
- Steps:
  1. In the app's Verify step, leave both "Compare with…" boxes on and click Verify. It only reads.
  2. Look at the result line, the numbers at the top and the chart.
  3. Click "Save as HTML…" and keep the report somewhere private (it lists Message-IDs and folder names, so do not share it).
- Expected: "Everything is accounted for". All Mail on Bridge equals All Mail in the store. Every folder's Expected, Apple Mail and iCloud bars are the same length, and Missing is 0. "Extra" messages that were already in iCloud before the upload are fine.
- Report back: the result line and the four numbers at the top, and any folder with a warning triangle (rename it if you like). Not the report itself. If it passes and you are happy, write "signed off" in the Result line below.
- Result:

### MT-006: Approve and watch the first real upload to iCloud
- Status: blocked (needs David's go-ahead in the project thread first)
- Added: 2026-11-02 by "Build the Proton to iCloud exporter"
- Phase / PR: Phase 5, (Phase 5 PR)
- Why David: his account; first real write to iCloud needs his approval
- Before you start: MT-003 and MT-005 passed. Tell the agent in the project thread "go ahead with the iCloud upload".
- Steps:
  1. In the app's Upload step, click "Check (writes nothing)" again and confirm the numbers look right.
  2. Click "Upload to iCloud…" and confirm.
  3. Watch it for a few minutes, then let it run. Pause and Resume once to check it carries on.
  4. When it finishes, open Mail on iCloud.com or your iPhone.
- Expected: the summary shows "Uploaded" equal to the planned number and 0 refused (or a few, with copies kept in "Not uploaded"). In iCloud the folders match Proton, dates are the original ones, read and unread state and flags match, and Unfiled holds the All Mail-only messages.
- Report back: the summary numbers, any refused count, and yes/no for folders, dates, read state, flags and attachments on a sample.
- Result:

### MT-005: Create an iCloud app-specific password and do a dry run
- Status: pending
- Added: 2026-11-02 by "Build the Proton to iCloud exporter"
- Phase / PR: Phase 5, (Phase 5 PR)
- Why David: sign-in, his account
- Before you start: MT-003 passed.
- Steps:
  1. Go to account.apple.com > Sign-In and Security > App-Specific Passwords, create one called "Slop Export", and copy it.
  2. In the app's Upload step, enter your Apple ID email and paste the app-specific password. It is saved in your Keychain.
  3. Click "Check (writes nothing)".
- Expected: it shows how many messages and how much space the upload needs, your iCloud storage use, and the folders it would create. Nothing changes in iCloud.
- Report back: the numbers shown, and whether it warned about storage.
- Result:

### MT-004: Import the Apple Mail mailboxes (Path A, optional)
- Status: pending
- Added: 2026-11-02 by "Build the Proton to iCloud exporter"
- Phase / PR: Phase 4, (Phase 3-4 PR)
- Why David: his device, human judgement
- Before you start: MT-003 passed.
- Steps:
  1. In the app's Export step, click "Build Apple Mail mailboxes".
  2. In Mail, choose File > Import Mailboxes…, pick "Apple Mail", and select the "Apple Mail Import" folder inside your export folder.
  3. Mail puts them under "Import" in the sidebar, On My Mac. Open a few folders.
  4. Don't drag anything into iCloud yet; the Upload step does that more reliably.
- Expected: the same folders as in Proton, with the right counts. Read and unread match Proton, starred messages are flagged, dates are the original ones, attachments open, and non-English subjects look right.
- Report back: yes/no for each of those, and how long the import took. If anything looks wrong, which folder and roughly what (no message content).
- Result:

### MT-003: Run a full export from your Bridge
- Status: pending
- Added: 2026-11-02 by "Build the Proton to iCloud exporter"
- Phase / PR: Phase 3, (Phase 3-4 PR)
- Why David: his account, his device
- Before you start: MT-002 passed, Bridge running and synced, enough free disk space for your mailbox (Scan shows the size).
- Steps:
  1. In the app, open Export and choose a folder (a new folder in Documents is fine).
  2. Click "Start export". Leave it running. Large mailboxes can take hours, since Bridge is slow.
  3. Partway through, click Pause, quit the app, reopen it, go to Export and click "Resume export".
- Expected: it carries on from where it stopped, then shows "Export complete" with the number of messages and how many are "Only in All Mail". Nothing in Proton is marked read.
- Report back: the two numbers, whether the resume worked, roughly how long it took, and the size of the "Proton Export" folder.
- Result:

### MT-002: Open the test build and scan your mailboxes
- Status: pending
- Added: 2026-11-02 by "Build the Proton to iCloud exporter"
- Phase / PR: Phase 1, (Phase 0-2 PR)
- Why David: his device, his account
- Before you start: MT-001 done, Bridge running and synced.
- Steps:
  1. Download `SlopExport-app` from the latest green CI run on `main` (Actions tab > CI > the run > Artifacts) and unzip it; it contains `SlopExport.zip` and `SlopExport.dmg`. (A proper GitHub Release comes in Phase 7.)
  2. Open the `.dmg` and drag Slop Export to Applications.
  3. Open it. macOS will say it cannot verify the developer. Open System Settings > Privacy & Security, scroll down, click "Open Anyway" next to Slop Export, and confirm.
  4. In the Connect step, type the IMAP user name Bridge shows for your account, click Choose… and pick the certificate from MT-001, and paste the Bridge password (from Bridge, not your Proton password) into the password field.
  5. Click "Connect and scan". If macOS asks whether Slop Export may use the Keychain, click Always Allow.
- Expected: the Scan step lists every Bridge mailbox with counts and sizes. `Labels/...` rows say "skipped (labels, D-001)". No mail is downloaded and nothing changes in Proton.
- Report back: the table with folder names blurred or renamed if you prefer, the "Messages to export" and "All Mail" numbers, and the server name and version shown at the top. If it fails, the red error text.
- Result:

### MT-001: Set up Bridge and export its certificate
- Status: pending
- Added: 2026-11-02 by "Build the Proton to iCloud exporter"
- Phase / PR: Phase 1, (Phase 0-2 PR)
- Why David: sign-in
- Before you start: a paid Proton plan (Bridge needs one).
- Steps:
  1. Install Proton Mail Bridge from proton.me/mail/bridge and sign in with your Proton account.
  2. Leave it running until it says your account is synced (large mailboxes can take hours).
  3. In Bridge, open Settings > Advanced settings > Export TLS certificates, and save `cert.pem` somewhere you can find it (Documents is fine).
  4. In Bridge, click your account and note the IMAP host, port, user name and connection security. Leave the password in Bridge for now; MT-002 tells you where it goes.
- Expected: host `127.0.0.1`, port `1143`, security STARTTLS (other values are fine, just report them).
- Report back: host, port and security mode. Not the password.
- Result:
