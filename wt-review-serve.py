#!/usr/bin/env python3
"""レビューページを 127.0.0.1 の使い捨て HTTP サーバで配信し、承認ボタンの
POST を herdr agent prompt に変換する。

`wt serve` から起動される (直接叩くのは動作確認のときだけ)。役割は 3 つ:

1. `GET /?token=...` でレビューページを返す。HTML は**リクエストごとに読み直す**
   ので、再レビュー (同じパスへの上書き) はブラウザのリロードだけで最新化される
2. `POST /approve` を `herdr agent prompt claude-<task> <承認文>` に変換する。
   承認は worktree セッションへの**ユーザーの直接入力**として届く
3. 承認が通ったら自分で終了する (使い捨て)

token は起動ごとのランダム値で、この 1 プロセスの間だけ有効。bind は 127.0.0.1
のみで、他所のページからの drive-by POST は token 不一致で落ちる。

標準ライブラリだけで動く。外部依存を足さない。
"""
import argparse
import http.server
import json
import os
import secrets
import signal
import subprocess
import sys
import threading
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

# 承認ボタンが worktree セッションへ投入する文。先頭が / ! # @ だと Claude Code が
# slash command / bash / memory / file mention として解釈するため平叙文で始める。
APPROVE_TEXT = "承認します。/wt-merge に進んでください"

# トークン無しで返す同梱アセット。ページの <script src> は query を引き継げないため
# token を要求できない。秘密を含まないものだけを許可する (allowlist)。
ASSETS = {"mermaid.min.js": "text/javascript; charset=utf-8"}

# 既定の寿命。承認されず放置されたサーバを永久に残さないための上限 (24 時間)。
DEFAULT_TTL = 86400


def log(msg):
    print(f"[serve] {msg}", file=sys.stderr, flush=True)


def die(msg):
    print(f"[serve] ERROR: {msg}", file=sys.stderr, flush=True)
    raise SystemExit(2)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "wt-review-serve"
    # HTTP/1.0 のまま使う (keep-alive を張らないので Content-Length だけ守れば足りる)。

    # ---------------------------------------------------------------- 応答

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _json(self, code, payload):
        self._send(code, json.dumps(payload, ensure_ascii=False),
                   "application/json; charset=utf-8")

    def _token_ok(self, given):
        if not isinstance(given, str):
            return False
        return secrets.compare_digest(given, self.server.wt_token)

    def log_message(self, fmt, *args):  # 既定の stderr ログを [serve] に揃える
        log(f"{self.address_string()} {fmt % args}")

    # ---------------------------------------------------------------- GET

    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/":
            token = parse_qs(parsed.query).get("token", [None])[0]
            if not self._token_ok(token):
                self._send(403, "token が一致しません。/wt-review が出した URL "
                                "をそのまま開いてください\n")
                return
            try:
                # 毎回読み直す。再レビューで上書きされた HTML をリロードで拾う。
                body = self.server.wt_html.read_bytes()
            except OSError as e:
                self._send(500, f"レビューページを読めません: {e}\n")
                return
            self._send(200, body, "text/html; charset=utf-8")
            return

        name = parsed.path.lstrip("/")
        ctype = ASSETS.get(name)
        if ctype:
            path = self.server.wt_html.parent / name
            if path.is_file():
                self._send(200, path.read_bytes(), ctype)
                return
        self._send(404, "not found\n")

    # ---------------------------------------------------------------- POST

    def do_POST(self):
        if urlsplit(self.path).path != "/approve":
            self._send(404, "not found\n")
            return

        # same-origin からの POST だけを受ける。Origin が無い (fetch の同一オリジン
        # 送信や curl) のは許し、別オリジンを名乗るものだけ落とす。
        origin = self.headers.get("Origin")
        if origin and origin not in self.server.wt_origins:
            self._json(403, {"ok": False, "error": f"別オリジンからの POST: {origin}"})
            return

        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length > 0 else b""
        token = self.headers.get("X-WT-Token")
        if token is None:
            try:
                token = json.loads(raw.decode("utf-8") or "{}").get("token")
            except (ValueError, UnicodeDecodeError):
                token = None
        if not self._token_ok(token):
            self._json(403, {"ok": False, "error": "token が一致しません"})
            return

        ok, detail = self.server.wt_approve()
        if not ok:
            self._json(500, {"ok": False, "error": detail})
            return
        self._json(200, {"ok": True, "agent": self.server.wt_agent})
        # 承認は 1 回きり。応答を返しきってから自分を畳む (使い捨て)。
        threading.Thread(target=self.server.shutdown, daemon=True).start()


class Server(http.server.ThreadingHTTPServer):
    """1 リクエストで固まっても他が詰まらないよう threading 版を使う。"""

    daemon_threads = True

    def wt_approve(self):
        cmd = ["herdr", "agent", "prompt", self.wt_agent, self.wt_message]
        log(f"承認を投入する: {' '.join(cmd[:4])}")
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except OSError as e:
            return False, f"herdr を実行できません: {e}"
        except subprocess.TimeoutExpired:
            return False, "herdr agent prompt が 30 秒で応答しません"
        if r.returncode != 0:
            detail = (r.stderr or r.stdout or "").strip().splitlines()
            tail = detail[-1] if detail else f"exit {r.returncode}"
            return False, f"herdr agent prompt が失敗しました: {tail}"
        return True, ""


def write_state(path, fields):
    """state を key=value で書く。読む側 (wt) に jq を要求しないための形式。

    途中まで書けたファイルを wt に読ませないよう、同ディレクトリの一時ファイルに
    書いてから置き換える。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text("".join(f"{k}={v}\n" for k, v in fields.items()), encoding="utf-8")
    os.replace(tmp, path)


def build_parser():
    p = argparse.ArgumentParser(
        description="レビューページを localhost の使い捨て HTTP サーバで配信する")
    p.add_argument("--html", required=True, type=Path, help="配信するレビューページ")
    p.add_argument("--task", required=True,
                   help="worktree の task 名。承認の宛先 claude-<task> になる")
    p.add_argument("--state", type=Path,
                   help="pid / port / token / url を書き出す state ファイル")
    p.add_argument("--message", default=APPROVE_TEXT,
                   help="承認時に投入する文 (既定: 承認します。/wt-merge に…)")
    p.add_argument("--ttl", type=int, default=DEFAULT_TTL, metavar="SEC",
                   help=f"この秒数で自分を畳む (既定: {DEFAULT_TTL})")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    html = args.html.expanduser().resolve()
    if not html.is_file():
        die(f"レビューページが無い: {html}")

    token = secrets.token_urlsafe(24)
    try:
        srv = Server(("127.0.0.1", 0), Handler)  # port 0 = 空きポート
    except OSError as e:
        die(f"127.0.0.1 に bind できない: {e}")
    port = srv.server_address[1]

    srv.wt_html = html
    srv.wt_token = token
    srv.wt_agent = f"claude-{args.task}"
    srv.wt_message = args.message
    srv.wt_origins = {f"http://localhost:{port}", f"http://127.0.0.1:{port}"}

    url = f"http://localhost:{port}/?token={token}"
    if args.state:
        write_state(args.state, {
            "pid": os.getpid(), "port": port, "token": token,
            "url": url, "html": html, "task": args.task,
        })
    print(url, flush=True)
    log(f"配信開始: {html} (agent {srv.wt_agent}, ttl {args.ttl}s)")

    # SIGTERM/SIGINT で畳む。shutdown() は serve_forever を待つので、シグナル
    # ハンドラ (= main thread) から直接呼ぶと自分待ちで固まる。別スレッドから叩く。
    def stop(*_):
        threading.Thread(target=srv.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    ttl = threading.Timer(max(args.ttl, 1), stop)
    ttl.daemon = True
    ttl.start()

    try:
        srv.serve_forever(poll_interval=0.2)
    finally:
        ttl.cancel()
        srv.server_close()
        if args.state:
            try:
                os.unlink(args.state)
            except OSError:
                pass
        log("終了した")


if __name__ == "__main__":
    main()
