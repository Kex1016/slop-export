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

_None yet._
