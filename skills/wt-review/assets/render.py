#!/usr/bin/env python3
"""net.diff とテンプレートからマージ前レビュー用の HTML を組み立てる。

固定資産 (CSS / JS / 骨格 / 節見出し) はテンプレートが持ち、毎回変わるもの
(タイトル・git のメタ情報・変更概要・テスト結果・diff) だけを差し込む。
プレースホルダーの契約と summary 断片で使えるクラスは同ディレクトリの
README.md を参照。

標準ライブラリだけで動く。外部依存を足さない。
"""
import argparse
import html
import re
import shutil
import subprocess
import sys
from pathlib import Path

MERMAID_URL = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"
MERMAID_CACHE = Path.home() / ".cache" / "wt" / "mermaid.min.js"

HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
FILE_RE = re.compile(r"^diff --git a/(.+?) b/(.+)$")
LEFTOVER_RE = re.compile(r"<!--[A-Z][A-Z0-9_]*-->")

# diff のヘッダ行。行番号を持たないので row にしない。
SKIP_PREFIXES = (
    "index ", "--- ", "+++ ", "new file mode", "deleted file mode",
    "similarity index", "dissimilarity index", "rename from", "rename to",
    "copy from", "copy to", "old mode", "new mode",
    "Binary files ", "GIT binary patch",
)


def die(msg):
    print(f"[render] ERROR: {msg}", file=sys.stderr)
    raise SystemExit(2)


def warn(msg):
    print(f"[render] 注意: {msg}", file=sys.stderr)


def esc(s):
    return html.escape(s, quote=False)


# ---------------------------------------------------------------- diff parse

def parse(text):
    """unified diff をファイル単位の行リストに畳む。"""
    files = []
    cur = None
    old_no = new_no = 0
    for line in text.rstrip("\n").split("\n"):
        m = FILE_RE.match(line)
        if m:
            cur = {"path": m.group(2), "rows": [], "add": 0, "del": 0}
            files.append(cur)
            old_no = new_no = 0  # 行番号はファイルを跨いで引き継がない
            continue
        if cur is None:
            continue
        if line.startswith(SKIP_PREFIXES):
            continue
        m = HUNK_RE.match(line)
        if m:
            old_no = int(m.group(1))
            new_no = int(m.group(3))
            cur["rows"].append(("hunk", "", "", line))
            continue
        if not cur["rows"]:  # 最初の hunk より前は行番号が決まらない
            continue
        if line.startswith("+"):
            cur["rows"].append(("add", "", new_no, line[1:]))
            cur["add"] += 1
            new_no += 1
        elif line.startswith("-"):
            cur["rows"].append(("del", old_no, "", line[1:]))
            cur["del"] += 1
            old_no += 1
        elif line.startswith("\\"):  # \ No newline at end of file
            cur["rows"].append(("ctx", "", "", line))
        elif line.startswith(" ") or line == "":
            cur["rows"].append(("ctx", old_no, new_no, line[1:] if line else ""))
            old_no += 1
            new_no += 1
    return files


# ---------------------------------------------------------------- diff の HTML

def summary_rows(files):
    top = max((f["add"] + f["del"] for f in files), default=0) or 1
    out = []
    for f in files:
        add_pct = f["add"] / top * 100
        del_pct = f["del"] / top * 100
        out.append(
            '<li class="filestat">'
            f'<span class="filestat-path">{esc(f["path"])}</span>'
            f'<span class="filestat-num"><span class="count-add">+{f["add"]}</span> '
            f'<span class="count-del">-{f["del"]}</span></span>'
            '<span class="bar" aria-hidden="true">'
            f'<span class="add" style="flex:0 0 {add_pct:.2f}%"></span>'
            f'<span class="del" style="flex:0 0 {del_pct:.2f}%"></span>'
            '<span class="rest"></span>'
            '</span>'
            '</li>'
        )
    return "\n      ".join(out)


CHEVRON = ('<svg class="diff-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" '
           'stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" '
           'aria-hidden="true"><path d="M9 18l6-6-6-6"></path></svg>')


def is_open(f, opened, collapsed, threshold):
    """折りたたみの判定。明示指定 > 行数閾値。"""
    if f["path"] in opened:
        return True
    if f["path"] in collapsed:
        return False
    return f["add"] + f["del"] <= threshold


def diff_blocks(files, opened, collapsed, threshold):
    out = []
    for f in files:
        f["open"] = is_open(f, opened, collapsed, threshold)
        attr = " open" if f["open"] else ""
        note = "" if f["open"] else '<span class="chip">折りたたみ</span>'
        rows = []
        for kind, old_no, new_no, content in f["rows"]:
            rows.append(
                f'<div class="diff-row {kind}">'
                f'<span class="ln">{old_no}</span>'
                f'<span class="ln">{new_no}</span>'
                f'<span class="code">{esc(content) or "&nbsp;"}</span>'
                f'</div>'
            )
        body = "\n".join(rows)
        out.append(
            f'<details class="diff-file"{attr}>\n'
            f'  <summary class="diff-summary">{CHEVRON}'
            f'<span class="diff-name">{esc(f["path"])}</span>'
            f'{note}'
            f'<span class="diff-counts"><span class="count-add">+{f["add"]}</span> '
            f'<span class="count-del">-{f["del"]}</span></span></summary>\n'
            f'  <div class="diff-body"><div class="diff-inner">\n{body}\n</div></div>\n'
            f'</details>'
        )
    return "\n".join(out)


# ---------------------------------------------------------------- git メタ情報

def git(*args):
    """git を叩いて stdout を返す。失敗したら None (git が無い場合も含む)。"""
    try:
        r = subprocess.run(("git", *args), capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    return r.stdout.strip()


def meta_cells(files, base, head):
    def cell(key, val):
        return (f'<div class="meta-cell">\n'
                f'        <p class="meta-key">{key}</p>\n'
                f'        <p class="meta-val">{val}</p>\n'
                f'      </div>')

    cells = []
    branch = git("rev-parse", "--abbrev-ref", head) if head else None
    if branch and branch != "HEAD":
        cells.append(cell("Branch", esc(branch)))
    if base:
        full = git("rev-parse", base) or base
        short = git("rev-parse", "--short", base) or base
        cells.append(cell("Base SHA", f'{esc(short)}<span class="sub">{esc(full)}</span>'))
    n = len(files)
    cells.append(cell("Net diff", f"{n} file" + ("s" if n != 1 else "")))
    add = sum(f["add"] for f in files)
    dele = sum(f["del"] for f in files)
    cells.append(cell("Lines",
                      f'<span class="count-add">+{add}</span> / '
                      f'<span class="count-del">-{dele}</span>'))
    return branch, "\n      ".join(cells)


def commit_rows(base, head):
    """base..head のコミットを古い順に組む。取れなければ None。"""
    out = git("log", "--reverse", "--format=%h%x1f%s", f"{base}..{head}")
    if out is None:
        return None
    entries = [l.split("\x1f", 1) for l in out.split("\n") if "\x1f" in l]
    if not entries:
        return None
    rows = []
    for i, (sha, subject) in enumerate(entries):
        last = i == len(entries) - 1
        cls = "commit commit-final" if last else "commit"
        chip = '<span class="chip chip-final">HEAD</span>' if last else ""
        rows.append(
            f'<li class="{cls}">\n'
            f'        <div class="commit-marker"><span class="node"></span></div>\n'
            f'        <div>\n'
            f'          <div class="commit-line">'
            f'<span class="commit-sha">{esc(sha)}</span>{chip}</div>\n'
            f'          <div class="commit-msg">{esc(subject)}</div>\n'
            f'        </div>\n'
            f'      </li>'
        )
    return "\n      ".join(rows)


# ---------------------------------------------------------------- テンプレート

def take_region(tpl, name, keep):
    """<!--NAME_BEGIN--> 〜 <!--NAME_END--> を、中身だけ残すか丸ごと落とす。"""
    pat = re.compile(r"[ \t]*<!--{0}_BEGIN-->\n(.*?)[ \t]*<!--{0}_END-->\n".format(name), re.S)
    m = pat.search(tpl)
    if m is None:
        die(f"テンプレートに {name} 領域が無い (<!--{name}_BEGIN--> / <!--{name}_END-->)")
    if keep:
        return tpl[:m.start()] + m.group(1) + tpl[m.end():]
    tail = m.end() + (1 if tpl[m.end():m.end() + 1] == "\n" else 0)  # 直後の空行も落とす
    return tpl[:m.start()] + tpl[tail:]


def ensure_mermaid(out_dir):
    """出力先に mermaid.min.js を用意する。できなければ False。"""
    dst = out_dir / "mermaid.min.js"
    if dst.exists():
        return True
    if not MERMAID_CACHE.exists():
        if shutil.which("curl") is None:
            warn("curl が無いため mermaid.min.js を取得できない")
            return False
        MERMAID_CACHE.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(["curl", "-fsSL", "-o", str(MERMAID_CACHE), MERMAID_URL])
        if r.returncode != 0:
            MERMAID_CACHE.unlink(missing_ok=True)
            warn(f"mermaid.min.js を取得できなかった ({MERMAID_URL})")
            return False
        print(f"[render] mermaid.min.js をキャッシュした: {MERMAID_CACHE}")
    shutil.copy(MERMAID_CACHE, dst)
    return True


# ---------------------------------------------------------------- CLI

def build_parser():
    p = argparse.ArgumentParser(
        description="net.diff とテンプレートからレビューページ HTML を組み立てる")
    p.add_argument("--diff", required=True, type=Path, help="git diff の出力 (net.diff)")
    p.add_argument("--out", required=True, type=Path, help="出力する HTML")
    p.add_argument("--title", required=True, help="ページタイトル (タスク名)")
    p.add_argument("--summary", required=True, type=Path,
                   help="変更概要の HTML 断片")
    p.add_argument("--tests", type=Path,
                   help="テスト結果の HTML 断片。省略すると「テスト結果」節を出さない")
    p.add_argument("--template", type=Path,
                   default=Path(__file__).resolve().parent / "wt-review-template.html",
                   help="テンプレート (既定: スクリプトと同ディレクトリ)")
    p.add_argument("--base", help="ベースコミット。指定するとメタ情報とコミット一覧を git から作る")
    p.add_argument("--head", default="HEAD", help="先頭コミット (既定: HEAD)")
    p.add_argument("--open", action="append", default=[], metavar="PATH",
                   help="このファイルの diff を開いた状態にする (複数指定可)")
    p.add_argument("--collapse", action="append", default=[], metavar="PATH",
                   help="このファイルの diff を折りたたむ (複数指定可)")
    p.add_argument("--collapse-threshold", type=int, default=200, metavar="N",
                   help="増減の合計が N 行を超えるファイルを折りたたむ (既定: 200)")
    p.add_argument("--no-mermaid", action="store_true",
                   help="mermaid の描画スクリプトを入れない")
    return p


def read(path, label):
    if not path.is_file():
        die(f"{label} が無い: {path}")
    return path.read_text(encoding="utf-8")


def main(argv=None):
    args = build_parser().parse_args(argv)

    diff_text = read(args.diff, "diff")
    tpl = read(args.template, "テンプレート")
    summary = read(args.summary, "要約断片")
    tests = read(args.tests, "テスト結果断片") if args.tests else None

    files = parse(diff_text)
    if not files:
        die(f"diff からファイルを 1 つも読めなかった: {args.diff}")

    opened, collapsed = set(args.open), set(args.collapse)
    known = {f["path"] for f in files}
    for path in sorted((opened | collapsed) - known):
        warn(f"--open / --collapse に diff に無いパスが指定されている: {path}")

    diff_html = diff_blocks(files, opened, collapsed, args.collapse_threshold)
    branch, meta = meta_cells(files, args.base, args.head)
    commits = commit_rows(args.base, args.head) if args.base else None

    fragments = summary + (tests or "")
    want_mermaid = not args.no_mermaid and 'class="mermaid"' in fragments
    has_mermaid = want_mermaid and ensure_mermaid(args.out.parent)
    if want_mermaid and not has_mermaid:
        warn("mermaid を描画しない。図は元のテキストのまま表示される")

    tpl = take_region(tpl, "COMMITS", commits is not None)
    tpl = take_region(tpl, "TESTS", tests is not None)
    tpl = take_region(tpl, "MERMAID", has_mermaid)
    tpl = tpl.replace("<!--TITLE-->", esc(args.title))
    tpl = tpl.replace("<!--BRANCH-->", esc(branch or ""))
    tpl = tpl.replace("<!--META-->", meta)
    tpl = tpl.replace("<!--COMMITS-->", commits or "")
    tpl = tpl.replace("<!--SUMMARY-->", summary.strip())
    tpl = tpl.replace("<!--TESTS-->", (tests or "").strip())
    tpl = tpl.replace("<!--FILE_SUMMARY-->", summary_rows(files))
    tpl = tpl.replace("<!--DIFF_SECTION-->", diff_html)

    left = sorted(set(LEFTOVER_RE.findall(tpl)))
    if left:
        die("埋まっていないプレースホルダーが残っている: " + " ".join(left))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(tpl, encoding="utf-8")

    add = sum(f["add"] for f in files)
    dele = sum(f["del"] for f in files)
    print(f"files={len(files)} +{add} -{dele}")
    for f in files:
        state = "open" if f["open"] else "collapsed"
        print(f'  {f["path"]}: +{f["add"]} -{f["del"]} rows={len(f["rows"])} {state}')
    print("bytes:", args.out.stat().st_size)


if __name__ == "__main__":
    main()
