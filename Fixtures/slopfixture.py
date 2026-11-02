#!/usr/bin/env python3
"""Synthetic IMAP fixture servers for slop-export tests.

Starts Dovecot as a plain process (no Docker needed) with a generated config,
TLS certificate and Maildir, seeded with synthetic mail that mirrors the
mailbox layout Proton Mail Bridge exposes. A second "icloud" kind stands in
for iCloud Mail (implicit TLS, Apple's folder names, empty).

Usage:
  slopfixture.py up   --dir DIR [--kind bridge|icloud|both]
  slopfixture.py down --dir DIR

After `up`, DIR/<kind>.json describes each server:
  {"host", "port", "security": "starttls"|"tls", "user", "password", "cert"}

No real mail, no real credentials: every message here is made up.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import pwd
import shutil
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from email.utils import format_datetime
from datetime import datetime, timezone, timedelta
from pathlib import Path

BRIDGE_USER = "fixture@example.test"
BRIDGE_PASSWORD = "fixture-bridge-password"
ICLOUD_USER = "fixture@icloud.example.test"
ICLOUD_PASSWORD = "fixture-icloud-password"
FIXTURE_UNIX_USER = "slopfixture"


# ---------------------------------------------------------------------------
# Synthetic corpus
# ---------------------------------------------------------------------------


@dataclass
class Msg:
    key: str
    raw: bytes
    date: datetime
    # mailbox name (IMAP, '/' separated, display form) -> maildir flag letters
    places: dict[str, str] = field(default_factory=dict)


def _date(y: int, mo: int, d: int, h: int = 10, mi: int = 0, tz_hours: int = 0) -> datetime:
    return datetime(y, mo, d, h, mi, tzinfo=timezone(timedelta(hours=tz_hours)))


def _simple(key: str, subject: str, date: datetime, body: str, *, mid: bool = True,
            frm: str = "Alice Example <alice@example.test>",
            to: str = "Fixture <fixture@example.test>",
            extra_headers: str = "", charset: str = "us-ascii") -> bytes:
    headers = f"From: {frm}\r\nTo: {to}\r\nSubject: {subject}\r\nDate: {format_datetime(date)}\r\n"
    if mid:
        headers += f"Message-ID: <{key}@fixture.example.test>\r\n"
    headers += "MIME-Version: 1.0\r\n"
    headers += f"Content-Type: text/plain; charset={charset}\r\nContent-Transfer-Encoding: 8bit\r\n"
    headers += extra_headers
    return headers.encode("ascii") + b"\r\n" + body.encode("utf-8" if charset != "us-ascii" else "ascii")


def _with_attachment(key: str, date: datetime, size: int) -> bytes:
    payload = bytes((i * 31 + 7) % 256 for i in range(size))
    b64 = base64.encodebytes(payload).replace(b"\n", b"\r\n")
    return (
        f"From: Bob Example <bob@example.test>\r\nTo: fixture@example.test\r\n"
        f"Subject: Big attachment\r\nDate: {format_datetime(date)}\r\n"
        f"Message-ID: <{key}@fixture.example.test>\r\nMIME-Version: 1.0\r\n"
        "Content-Type: multipart/mixed; boundary=\"slopboundary\"\r\n\r\n"
        "--slopboundary\r\nContent-Type: text/plain; charset=us-ascii\r\n\r\n"
        "See attached.\r\n"
        "--slopboundary\r\nContent-Type: application/octet-stream; name=\"blob.bin\"\r\n"
        "Content-Disposition: attachment; filename=\"blob.bin\"\r\n"
        "Content-Transfer-Encoding: base64\r\n\r\n"
    ).encode("ascii") + b64 + b"--slopboundary--\r\n"


def corpus(attachment_bytes: int) -> list[Msg]:
    m: list[Msg] = []

    m.append(Msg("m01-unread", _simple("m01-unread", "Unread hello", _date(2019, 3, 4), "Plain unread message.\r\n"),
                 _date(2019, 3, 4), {"INBOX": ""}))
    m.append(Msg("m02-starred-utf8",
                 _simple("m02-starred-utf8", "=?UTF-8?B?" + base64.b64encode("Grüße aus Köln ✉".encode()).decode() + "?=",
                         _date(2020, 7, 14, 18, 30, 2), "Schöne Grüße, señor. 日本語のテキスト。\r\n", charset="utf-8"),
                 _date(2020, 7, 14, 16, 30), {"INBOX": "FS", "Starred": "FS", "Labels/Important": "FS"}))
    m.append(Msg("m03-sent-answered", _simple("m03-sent-answered", "Re: Plans", _date(2021, 1, 2, 9, 15, -5),
                                              "Sounds good.\r\n", frm="Fixture <fixture@example.test>",
                                              to="Alice Example <alice@example.test>"),
                 _date(2021, 1, 2, 14, 15), {"Sent": "RS"}))
    m.append(Msg("m04-draft", _simple("m04-draft", "Unfinished draft", _date(2022, 5, 6), "Half a thought\r\n"),
                 _date(2022, 5, 6), {"Drafts": "DS"}))
    m.append(Msg("m05-attachment", _with_attachment("m05-attachment", _date(2018, 11, 30), attachment_bytes),
                 _date(2018, 11, 30), {"Archive": "S"}))
    latin1 = (
        b"From: Caf\xe9 <cafe@example.test>\r\nTo: fixture@example.test\r\n"
        b"Subject: Men\xfc f\xfcr heute\r\nDate: " + format_datetime(_date(2017, 2, 3)).encode() + b"\r\n"
        b"Message-ID: <m06-latin1@fixture.example.test>\r\nMIME-Version: 1.0\r\n"
        b"Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
        b"Gr\xfc\xdfe und sch\xf6nen Tag.\r\n"
    )
    m.append(Msg("m06-latin1", latin1, _date(2017, 2, 3), {"Folders/Work/Projects": "S"}))
    m.append(Msg("m07-no-message-id", _simple("m07-no-message-id", "No Message-ID here", _date(2016, 8, 9),
                                              "This message has no Message-ID header.\r\n", mid=False),
                 _date(2016, 8, 9), {"Folders/Work": ""}))
    m.append(Msg("m08-spam", _simple("m08-spam", "You won", _date(2023, 4, 1), "Spam body.\r\n"),
                 _date(2023, 4, 1), {"Spam": ""}))
    m.append(Msg("m09-trash", _simple("m09-trash", "Old newsletter", _date(2015, 12, 24), "Bin me.\r\n"),
                 _date(2015, 12, 24), {"Trash": "S"}))
    # Same bytes as m01, as a separate message in another folder.
    m.append(Msg("m10-duplicate-of-m01", m[0].raw, _date(2019, 3, 4), {"Folders/Ünïcödé Ordner": "S"}))
    m.append(Msg("m11-allmail-only",
                 _simple("m11-allmail-only", "Only in All Mail", _date(2024, 2, 29), "Label-only receipt.\r\n"),
                 _date(2024, 2, 29), {"Labels/Receipts": "S"}))
    m.append(Msg("m12-from-line",
                 _simple("m12-from-line", "Body with From lines", _date(2024, 6, 1),
                         "Hello\r\nFrom the start of a line\r\n>From already quoted\r\nBye\r\n"),
                 _date(2024, 6, 1), {"Folders/Ünïcödé Ordner": "S"}))

    # Starred, but in no folder (a label-only message with a star): stored from Starred, and
    # must not be downloaded a second time for All Mail.
    m.append(Msg("m13-starred-unfiled",
                 _simple("m13-starred-unfiled", "Starred receipt", _date(2024, 9, 9), "Starred, no folder.\r\n"),
                 _date(2024, 9, 9), {"Starred": "FS", "Labels/Receipts": "FS"}))

    # All Mail: every distinct message once (m02's label copy is the same message).
    for msg in m:
        msg.places["All Mail"] = next(iter(msg.places.values()))
    return m


BRIDGE_MAILBOXES = [
    "INBOX", "Sent", "Drafts", "Archive", "Spam", "Trash", "Starred", "All Mail",
    "Folders/Work", "Folders/Work/Projects", "Folders/Ünïcödé Ordner", "Folders/Empty",
    "Labels/Important", "Labels/Receipts",
]
ICLOUD_MAILBOXES = ["INBOX", "Sent Messages", "Drafts", "Archive", "Junk", "Deleted Messages"]


# ---------------------------------------------------------------------------
# Maildir seeding
# ---------------------------------------------------------------------------


def mutf7_encode(s: str) -> str:
    """RFC 3501 modified UTF-7, which Dovecot uses for maildir folder names."""
    out, buf = [], []

    def flush() -> None:
        if buf:
            b = "".join(buf).encode("utf-16-be")
            out.append("&" + base64.b64encode(b).decode().rstrip("=").replace("/", ",") + "-")
            buf.clear()

    for ch in s:
        if 0x20 <= ord(ch) <= 0x7E:
            flush()
            out.append("&-" if ch == "&" else ch)
        else:
            buf.append(ch)
    flush()
    return "".join(out)


def maildir_path(root: Path, mailbox: str) -> Path:
    if mailbox == "INBOX":
        return root
    return root.joinpath(*[mutf7_encode(p) for p in mailbox.split("/")])


def make_maildir(path: Path) -> None:
    for sub in ("cur", "new", "tmp"):
        (path / sub).mkdir(parents=True, exist_ok=True)


def seed(maildir: Path, mailboxes: list[str], messages: list[Msg]) -> None:
    for mb in mailboxes:
        make_maildir(maildir_path(maildir, mb))
    counter = 0
    for msg in messages:
        for mb, flags in msg.places.items():
            counter += 1
            ts = int(msg.date.timestamp())
            name = f"{ts}.M{counter}P1.fixture,S={len(msg.raw)}:2,{''.join(sorted(flags))}"
            f = maildir_path(maildir, mb) / "cur" / name
            f.write_bytes(msg.raw)
            os.utime(f, (ts, ts))
    # Subscriptions file so LIST shows everything as subscribed, like Bridge.
    (maildir / "subscriptions").write_text("V\t2\n\n" + "\t".join(mailboxes) + "\n")


# ---------------------------------------------------------------------------
# Dovecot
# ---------------------------------------------------------------------------


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def make_cert(d: Path) -> None:
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(d / "key.pem"),
         "-out", str(d / "cert.pem"), "-days", "3650", "-subj", "/CN=127.0.0.1",
         "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost"],
        check=True, capture_output=True)


def ensure_unix_user() -> tuple[str, int, int]:
    if os.geteuid() != 0:
        pw = pwd.getpwuid(os.geteuid())
        return pw.pw_name, pw.pw_uid, pw.pw_gid
    try:
        pw = pwd.getpwnam(FIXTURE_UNIX_USER)
    except KeyError:
        subprocess.run(["useradd", "--system", "--no-create-home", FIXTURE_UNIX_USER], check=True)
        pw = pwd.getpwnam(FIXTURE_UNIX_USER)
    return pw.pw_name, pw.pw_uid, pw.pw_gid


# What Proton Mail Bridge 3.x advertises after login. Advertising only this
# keeps the client honest: no STATUS=SIZE, no QUOTA, no CONDSTORE.
BRIDGE_CAPABILITIES = "IMAP4rev1 ID IDLE MOVE UIDPLUS UNSELECT LITERAL+"


def write_config(d: Path, port: int, implicit_tls: bool, user: str, password: str) -> Path:
    uname, uid, gid = ensure_unix_user()
    root = os.geteuid() == 0
    login_user = "dovenull" if root else uname
    internal_user = "dovecot" if root else uname
    (d / "passwd").write_text(f"{user}:{{PLAIN}}{password}\n")
    listeners = (
        f"  inet_listener imap {{\n    port = 0\n  }}\n  inet_listener imaps {{\n    port = {port}\n    ssl = yes\n  }}\n"
        if implicit_tls else
        f"  inet_listener imap {{\n    port = {port}\n  }}\n  inet_listener imaps {{\n    port = 0\n  }}\n"
    )
    conf = f"""
base_dir = {d}/run
state_dir = {d}/state
log_path = {d}/dovecot.log
protocols = imap
listen = 127.0.0.1
default_internal_user = {internal_user}
default_login_user = {login_user}
first_valid_uid = {min(uid, 1)}
ssl = required
ssl_cert = <{d}/cert.pem
ssl_key = <{d}/key.pem
disable_plaintext_auth = yes
auth_mechanisms = plain login
mail_plugins = $mail_plugins quota
protocol imap {{
  mail_plugins = $mail_plugins imap_quota
}}
plugin {{
  quota = count:User quota
  quota_rule = *:storage=1G
  quota_vsizes = yes
}}
passdb {{
  driver = passwd-file
  args = scheme=PLAIN username_format=%u {d}/passwd
}}
userdb {{
  driver = static
  args = uid={uid} gid={gid} home={d}/home
}}
mail_location = maildir:~/Maildir:LAYOUT=fs
namespace inbox {{
  inbox = yes
  separator = /
}}
service imap-login {{
  chroot =
{listeners}}}
service anvil {{
  chroot =
}}
"""
    if not implicit_tls:
        conf += f"protocol imap {{\n  imap_capability = {BRIDGE_CAPABILITIES}\n}}\n"
    path = d / "dovecot.conf"
    path.write_text(conf)
    return path


def wait_for_port(port: int, greeting: bool, timeout: float = 15.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1) as s:
                # Implicit-TLS servers say nothing until the handshake.
                if not greeting or s.recv(64):
                    return
        except OSError:
            time.sleep(0.2)
    raise SystemExit(f"fixture server on port {port} did not start")


def up_one(base: Path, kind: str, attachment_bytes: int) -> dict[str, object]:
    d = base / kind
    if d.exists():
        down_one(base, kind)
        shutil.rmtree(d)
    for sub in ("run", "state", "home"):
        (d / sub).mkdir(parents=True)
    os.chmod(base, 0o755)
    os.chmod(d, 0o755)
    make_cert(d)
    implicit = kind == "icloud"
    user, password = (ICLOUD_USER, ICLOUD_PASSWORD) if implicit else (BRIDGE_USER, BRIDGE_PASSWORD)
    port = free_port()
    conf = write_config(d, port, implicit, user, password)
    maildir = d / "home" / "Maildir"
    if implicit:
        seed(maildir, ICLOUD_MAILBOXES, [])
    else:
        seed(maildir, BRIDGE_MAILBOXES, corpus(attachment_bytes))
    _, uid, gid = ensure_unix_user()
    for p in [d / "home", *(d / "home").rglob("*")]:
        os.chown(p, uid, gid)
    subprocess.run(["dovecot", "-c", str(conf)], check=True)
    wait_for_port(port, greeting=not implicit)
    info = {"host": "127.0.0.1", "port": port, "security": "tls" if implicit else "starttls",
            "user": user, "password": password, "cert": str(d / "cert.pem")}
    (base / f"{kind}.json").write_text(json.dumps(info, indent=2))
    return info


def down_one(base: Path, kind: str) -> None:
    conf = base / kind / "dovecot.conf"
    if conf.exists():
        subprocess.run(["doveadm", "-c", str(conf), "stop"], capture_output=True)
        pidfile = base / kind / "run" / "master.pid"
        if pidfile.exists():
            try:
                os.kill(int(pidfile.read_text().strip()), signal.SIGTERM)
            except (ProcessLookupError, ValueError):
                pass


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["up", "down"])
    ap.add_argument("--dir", required=True, type=Path)
    ap.add_argument("--kind", choices=["bridge", "icloud", "both"], default="both")
    ap.add_argument("--attachment-bytes", type=int, default=3 * 1024 * 1024,
                    help="size of the large attachment in the bridge corpus")
    a = ap.parse_args()
    base: Path = a.dir.resolve()
    base.mkdir(parents=True, exist_ok=True)
    kinds = ["bridge", "icloud"] if a.kind == "both" else [a.kind]
    for k in kinds:
        if a.action == "up":
            info = up_one(base, k, a.attachment_bytes)
            print(f"{k}: {info['host']}:{info['port']} ({info['security']}) -> {base / (k + '.json')}")
        else:
            down_one(base, k)
    return 0


if __name__ == "__main__":
    sys.exit(main())
