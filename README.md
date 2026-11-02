# Slop Export

A Mac app that copies all your Proton Mail into iCloud Mail. It reads your mail through Proton Mail Bridge, keeps a full copy on your Mac, and then uploads that copy to iCloud with folders, dates, and read and flag state kept.

It never changes anything in Proton: it only reads. It never sees your Proton or Apple ID password. Bridge has its own password, and iCloud uses an app-specific password. Both are stored in your Mac's Keychain.

## What you need

- A Mac with macOS 14 (Sonoma) or newer.
- A paid Proton plan, which Bridge requires.
- [Proton Mail Bridge](https://proton.me/mail/bridge), installed and signed in.
- Enough free disk space for all your mail, plus about the same again if you also build the Apple Mail mailboxes.
- For the upload: enough free iCloud storage. The app checks this before it writes anything.

## 1. Install the app

1. Download `SlopExport.dmg` from the [latest release](https://github.com/Kex1016/slop-export/releases/latest).
2. Open it and drag **Slop Export** to Applications.
3. Open Slop Export. macOS will say it cannot verify the developer, because the app is not signed with an Apple Developer ID yet.
4. Open **System Settings › Privacy & Security** and scroll down. Click **Open Anyway** next to Slop Export, then confirm. You only do this once.

## 2. Set up Bridge

1. Sign in to Bridge and wait until it says your account is synced. A large mailbox can take hours.
2. In Bridge, open **Settings › Advanced settings › Export TLS certificates**. Save `cert.pem` somewhere you can find it, for example Documents.
3. Click your account in Bridge and keep the window open. You need the IMAP user name and password it shows. That password is not your Proton password.

## 3. Use the app

The steps are in the sidebar. **⌘1** to **⌘5** jump between them.

**Connect.** Enter the user name from Bridge and paste the Bridge password, which is saved to your Keychain. Click **Choose…** to pick `cert.pem`. The host and port are normally `127.0.0.1` and `1143`. Click **Connect and scan**. If macOS asks whether Slop Export may use the Keychain, click **Always Allow**.

**Scan.** Lists every Bridge mailbox with message counts and sizes. Nothing is downloaded yet. Mailboxes under `Labels/` are skipped on purpose; only folders are copied.

**Export.** Choose a folder with enough space, then click **Start export**.
- Messages are saved there one by one. You can **Pause**, or even quit the app, and **Resume export** later: it picks up where it stopped and never saves anything twice.
- Messages that are only in All Mail, in no folder, go to a folder called **Unfiled**.
- Starred messages are flagged.

**Verify.** Click **Verify** to check that every message is accounted for. The check compares:
- Bridge with your export;
- your export with the Apple Mail mailboxes, if you built them;
- your export with iCloud, once you have uploaded.

It only reads. The chart and table show each folder, and any problem is listed in words. **Save as HTML…** keeps a copy of the report. That report lists folder names and message IDs, so keep it private.

**Upload.**
1. Create an app-specific password at [account.apple.com](https://account.apple.com) › **Sign-In and Security › App-Specific Passwords**.
2. Enter your Apple ID email and that password. The password goes to your Keychain.
3. Click **Check (writes nothing)** to see how many messages will be uploaded, how much space they need, and which folders will be created.
4. Click **Upload to iCloud…** and confirm.

You can pause and resume the upload. Messages already in iCloud are skipped, so running it again is safe.

If iCloud refuses a single message (usually because it is too large), a copy is kept in **Not uploaded** inside the export folder. If iCloud refuses several in a row or says it is out of space, the upload stops so nothing is lost. Run it again later.

When the upload finishes, run **Verify** again with "Compare with iCloud Mail" turned on.

### Alternative: import with Apple Mail instead

In the Export step, click **Build Apple Mail mailboxes**. Then in Mail choose **File › Import Mailboxes…** and pick the **Apple Mail Import** folder inside your export folder. Then drag the imported mailboxes into your iCloud account. This is slower and less reliable for very large mailboxes, so the Upload step is recommended.

## 4. Check the result in iCloud

Open Mail on iCloud.com or your iPhone and spot-check a few messages:
- the folders match Proton;
- dates are the original ones;
- read and unread state, flags and answered state match;
- attachments open, and non-English text displays correctly;
- Unfiled holds the messages that were only in All Mail.

## Where your data goes

- The export folder you choose holds your mail as plain `.eml` files, plus progress files (`journal.jsonl`, `upload.jsonl`, `manifest.json`). Delete it when you are done.
- Nothing is sent anywhere except iCloud, and only when you click Upload.
- Your Bridge and iCloud app-specific passwords are in the Keychain under `slop-export.bridge` and `slop-export.icloud`. You can delete them in Keychain Access. You can revoke the app-specific password at account.apple.com.

## Troubleshooting

- **"certificate" or TLS errors on Connect:** Bridge's certificate has probably changed, for example after reinstalling Bridge. Export it from Bridge again and choose the new file.
- **Connect fails right away:** check that Bridge is running and the port matches what Bridge shows. Bridge defaults to STARTTLS on port 1143.
- **Counts on Scan look low:** Bridge may still be syncing. Wait until it finishes, then scan again.
- **iCloud says the password is wrong:** use an app-specific password, not your Apple ID password.

## For developers

The app is a SwiftUI front end on `SlopCore`, a Swift package that also powers a command-line tool (`swift run slop-export --help`) used for testing against local Dovecot fixture servers. `CLAUDE.md` has the build and test commands. `PLAN.md`, `DECISIONS.md` and `MANUAL-TESTS.md` describe the plan, the choices made and the checks only a person can do.
