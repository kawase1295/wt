#!/usr/bin/env bash
# wt のテスト。依存は git と coreutils のみ (bats 不要)。
#
#   tests/wt_test.sh
#
# herdr を PATH から隠して git worktree フォールバック経路を強制し、
# HOME を temp に差し替えて実ホーム (~/.herdr) を汚さずに検証する。
set -uo pipefail

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wt"

# herdr を含まない最小 PATH。coreutils / git だけ見えればよい。
SAFE_PATH="/usr/bin:/bin"

FAILED=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  FAILED=1
}
assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected='$2' actual='$3')"; fi
}
assert_dir() { # path desc
  if [ -d "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi
}
assert_no_dir() { # path desc
  if [ ! -d "$1" ]; then pass "$2"; else fail "$2 (unexpected: $1)"; fi
}
assert_file() { # path desc — symlink でない実体ファイル
  if [ -f "$1" ] && [ ! -L "$1" ]; then pass "$2"; else fail "$2 (not a regular file: $1)"; fi
}
assert_link() { # path desc
  if [ -L "$1" ]; then pass "$2"; else fail "$2 (not a symlink: $1)"; fi
}
branch_of() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null; }
has_branch() { git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null 2>&1; }

new_repo() {
  local d="$1"
  git init -q "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name tester
  git -C "$d" commit -q --allow-empty -m init
}

# フォールバック経路 (herdr 無し) で wt を実行する。HOME は temp、WT_HOME は未設定。
wt_local() { # repo args...
  local repo="$1"
  shift
  (cd "$repo" && env -u WT_HOME HOME="$TMP/home" PATH="$SAFE_PATH" "$WT" "$@")
}

TMP="$(mktemp -d)"
mkdir -p "$TMP/home"
trap 'rm -rf "$TMP"' EXIT

# --- test 1: WT_HOME 未設定なら repo-local の .claude/worktrees に作る ---
R1="$TMP/repo1"
new_repo "$R1"
wt_local "$R1" new feature-x --no-claude >/dev/null 2>&1
assert_dir "$R1/.claude/worktrees/feature-x" "new: <repo>/.claude/worktrees/<task> に作成する"
assert_no_dir "$TMP/home/.herdr/worktrees/repo1/feature-x" "new: 旧 herdr 位置には作らない"
assert_eq "new: ブランチは worktree-<task>" "worktree-feature-x" "$(branch_of "$R1/.claude/worktrees/feature-x")"

# --- test 2: WT_HOME を明示したら従来のグローバル位置に作る (後方互換) ---
R2="$TMP/repo2"
new_repo "$R2"
(cd "$R2" && HOME="$TMP/home" PATH="$SAFE_PATH" WT_HOME="$TMP/wthome" "$WT" new feat-y --no-claude) >/dev/null 2>&1
assert_dir "$TMP/wthome/repo2/feat-y" "new: WT_HOME 指定時は従来位置に作る"
assert_no_dir "$R2/.claude/worktrees/feat-y" "new: WT_HOME 指定時は .claude/worktrees に作らない"
assert_eq "new: WT_HOME 指定でもブランチは worktree-<task>" "worktree-feat-y" "$(branch_of "$TMP/wthome/repo2/feat-y")"

# --- test 3: rm は task 名で worktree とブランチを削除する ---
wt_local "$R1" rm feature-x >/dev/null 2>&1
assert_no_dir "$R1/.claude/worktrees/feature-x" "rm: worktree を削除する"
if has_branch "$R1" "worktree-feature-x"; then fail "rm: ブランチ worktree-<task> を削除する"; else pass "rm: ブランチ worktree-<task> を削除する"; fi

# --- test 4: 既存ブランチ名の衝突は task 名基準で検知する ---
R3="$TMP/repo3"
new_repo "$R3"
git -C "$R3" branch worktree-dup >/dev/null 2>&1
if wt_local "$R3" new dup --no-claude >/dev/null 2>&1; then
  fail "new: 既存ブランチ worktree-<task> があれば中断する"
else
  pass "new: 既存ブランチ worktree-<task> があれば中断する"
fi

# --- test 5: 非 git ディレクトリでは整形メッセージで中断する (指摘1) ---
NG="$TMP/not-a-repo"
mkdir -p "$NG"
out="$(cd "$NG" && env -u WT_HOME HOME="$TMP/home" PATH="$SAFE_PATH" "$WT" new xx --no-claude 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'git リポジトリ内'; then
  pass "new: 非 git ディレクトリで適切に中断する"
else
  fail "new: 非 git ディレクトリで適切に中断する (rc=$rc out=$out)"
fi

# --- test 6: --base の値欠落は整形エラーで中断する (指摘2) ---
out="$(wt_local "$R1" new needbase --base 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '値が必要'; then
  pass "new: --base の値欠落を整形エラーで弾く"
else
  fail "new: --base の値欠落を整形エラーで弾く (rc=$rc out=$out)"
fi

# --- test 7: 不正な task 名は中断し、通常名は許可する (指摘3) ---
out="$(wt_local "$R1" new "bad name" --no-claude 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'task 名'; then pass "new: スペースを含む task 名を整形エラーで弾く"; else fail "new: スペースを含む task 名を整形エラーで弾く (rc=$rc out=$out)"; fi
if wt_local "$R1" new "bad/name" --no-claude >/dev/null 2>&1; then fail "new: スラッシュを含む task 名を弾く"; else pass "new: スラッシュを含む task 名を弾く"; fi
wt_local "$R1" new ok.name-1_2 --no-claude >/dev/null 2>&1
assert_dir "$R1/.claude/worktrees/ok.name-1_2" "new: 英数と . _ - を含む名前は許可する"
wt_local "$R1" rm ok.name-1_2 >/dev/null 2>&1

# --- test 8: rm は余分な位置引数を弾く (指摘5) ---
out="$(wt_local "$R1" rm aa bb 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '引数が多すぎる'; then pass "rm: 引数が多すぎる場合は中断する"; else fail "rm: 引数が多すぎる場合は中断する (rc=$rc out=$out)"; fi

# --- test 9: .worktreeinclude に列挙した gitignore 済みファイルを実体コピーする ---
R9="$TMP/repo9"
new_repo "$R9"
printf 'config.local.json\n' >"$R9/.gitignore"
printf 'config.local.json\n' >"$R9/.worktreeinclude"
git -C "$R9" add .gitignore .worktreeinclude
git -C "$R9" commit -qm include
printf '{"secret":1}\n' >"$R9/config.local.json"
wt_local "$R9" new inc-basic --no-claude >/dev/null 2>&1
W9="$R9/.claude/worktrees/inc-basic"
assert_file "$W9/config.local.json" "include: 実体ファイルとしてコピーする"
assert_eq "include: コピー内容が一致する" '{"secret":1}' "$(cat "$W9/config.local.json" 2>/dev/null)"

# --- test 10: ディレクトリパターン (末尾スラッシュ) はネストしたファイルごとコピーする ---
R10="$TMP/repo10"
new_repo "$R10"
printf 'secrets/\n' >"$R10/.gitignore"
printf 'secrets/\n' >"$R10/.worktreeinclude"
git -C "$R10" add .gitignore .worktreeinclude
git -C "$R10" commit -qm include
mkdir -p "$R10/secrets/a"
printf 'key-data\n' >"$R10/secrets/a/b.key"
wt_local "$R10" new inc-dir --no-claude >/dev/null 2>&1
assert_file "$R10/.claude/worktrees/inc-dir/secrets/a/b.key" "include: ディレクトリパターンでネストごとコピーする"

# --- test 11: bootstrap 再実行は worktree 側の既存ファイルを上書きしない ---
printf 'edited-in-worktree\n' >"$W9/config.local.json"
wt_local "$R9" bootstrap "$W9" >/dev/null 2>&1
assert_eq "include: 再 bootstrap で既存ファイルを上書きしない" "edited-in-worktree" "$(cat "$W9/config.local.json" 2>/dev/null)"

# --- test 12: .worktreeinclude の .env は実体コピーが symlink に優先する ---
R12="$TMP/repo12"
new_repo "$R12"
printf '.env\n' >"$R12/.gitignore"
printf '.env\n' >"$R12/.worktreeinclude"
git -C "$R12" add .gitignore .worktreeinclude
git -C "$R12" commit -qm include
printf 'KEY=1\n' >"$R12/.env"
wt_local "$R12" new inc-env --no-claude >/dev/null 2>&1
assert_file "$R12/.claude/worktrees/inc-env/.env" "include: .env は実体コピーが symlink に優先する"
# 回帰: .worktreeinclude が無い repo では .env は従来どおり symlink
R12B="$TMP/repo12b"
new_repo "$R12B"
printf 'KEY=1\n' >"$R12B/.env"
wt_local "$R12B" new no-inc --no-claude >/dev/null 2>&1
assert_link "$R12B/.claude/worktrees/no-inc/.env" "include 無し: .env は従来どおり symlink する"

# --- test 13: .worktreeinclude のパターンが何にもマッチしなくてもエラーにしない ---
R13="$TMP/repo13"
new_repo "$R13"
printf 'no-such-file-anywhere\n' >"$R13/.worktreeinclude"
git -C "$R13" add .worktreeinclude
git -C "$R13" commit -qm include
if wt_local "$R13" new inc-empty --no-claude >/dev/null 2>&1; then
  pass "include: マッチ 0 件でも exit 0"
else
  fail "include: マッチ 0 件でも exit 0"
fi

# --- test 14: prompt の引数エラーは worktree を作る前に fail-fast する ---
R14="$TMP/repo14"
new_repo "$R14"
assert_prompt_err() { # desc pattern args...
  local desc="$1" pattern="$2"
  shift 2
  local out rc
  out="$(wt_local "$R14" new "$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "$pattern"; then
    pass "prompt: $desc"
  else
    fail "prompt: $desc (rc=$rc out=$out)"
  fi
}
assert_prompt_err "--prompt の値欠落を弾く" '値が必要' p14a --prompt
assert_prompt_err "--prompt と --prompt-file の併用を弾く" '併用できない' p14b --prompt x --prompt-file "$TMP/nope"
assert_prompt_err "--prompt-file の不存在を弾く" '見つからない' p14c --prompt-file "$TMP/no-such-file"
assert_prompt_err "--prompt と --no-claude の併用を弾く" '併用できない' p14d --prompt x --no-claude
for t in p14a p14b p14c p14d; do
  if [ -d "$R14/.claude/worktrees/$t" ] || has_branch "$R14" "worktree-$t"; then
    fail "prompt: エラー時に worktree/ブランチを作らない ($t)"
  else
    pass "prompt: エラー時に worktree/ブランチを作らない ($t)"
  fi
done

# --- test 14b: プロンプト本文の先頭 / ! # @ も worktree を作る前に弾く ---
# Claude Code が slash command / bash / memory / file mention として解釈するため。
assert_prompt_err "先頭 / を弾く" '先頭文字' p14e --prompt "/wt-review でレビューする"
assert_prompt_err "先頭 ! を弾く" '先頭文字' p14f --prompt "!ls を実行する"
assert_prompt_err "先頭 # を弾く" '先頭文字' p14g --prompt "#4 の対応をする"
assert_prompt_err "先頭 @ を弾く" '先頭文字' p14h --prompt "@README.md を読む"
assert_prompt_err "先頭の空白・改行越しでも弾く" '先頭文字' p14i --prompt $'  \n\t/wt-review でレビューする'
P14J="$TMP/prompt-lead.txt"
printf '\n  @README.md を読む\n' >"$P14J"
assert_prompt_err "--prompt-file の本文先頭も弾く" '先頭文字' p14j --prompt-file "$P14J"
for t in p14e p14f p14g p14h p14i p14j; do
  if [ -d "$R14/.claude/worktrees/$t" ] || has_branch "$R14" "worktree-$t"; then
    fail "prompt: 先頭文字エラーで worktree/ブランチを作らない ($t)"
  else
    pass "prompt: 先頭文字エラーで worktree/ブランチを作らない ($t)"
  fi
done
# 正常系: 平叙文で始まれば先頭文字チェックを通り、次の herdr チェックまで進む
out="$(wt_local "$R14" new p14k --prompt "実装したら /wt-review を呼ぶ #4" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'herdr' &&
  ! printf '%s' "$out" | grep -q '先頭文字'; then
  pass "prompt: 本文途中の / # は先頭文字チェックに掛からない"
else
  fail "prompt: 本文途中の / # は先頭文字チェックに掛からない (rc=$rc out=$out)"
fi

# --- test 15: herdr 不可で --prompt はプロンプトを取りこぼさないよう die する ---
out="$(wt_local "$R14" new p15 --prompt "hello" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'herdr'; then
  pass "prompt: herdr 不可なら die してプロンプトを取りこぼさない"
else
  fail "prompt: herdr 不可なら die してプロンプトを取りこぼさない (rc=$rc out=$out)"
fi
assert_no_dir "$R14/.claude/worktrees/p15" "prompt: herdr 不可の die でも worktree を作らない"

# --- test 16: merge は worktree 内から task 省略で実行でき、本体に取り込まれる ---
R16="$TMP/repo16"
new_repo "$R16"
wt_local "$R16" new m16 --no-claude >/dev/null 2>&1
W16="$R16/.claude/worktrees/m16"
printf 'done\n' >"$W16/result.txt"
git -C "$W16" add result.txt
git -C "$W16" commit -qm "add result"
if wt_local "$W16" merge >/dev/null 2>&1; then
  pass "merge: worktree 内から task 省略で実行できる"
else
  fail "merge: worktree 内から task 省略で実行できる"
fi
assert_file "$R16/result.txt" "merge: worktree のコミットが本体に取り込まれる"

# --- test 17: merge のガード ---
out="$(wt_local "$R16" merge 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'task'; then
  pass "merge: 本体で task 省略なら die する"
else
  fail "merge: 本体で task 省略なら die する (rc=$rc out=$out)"
fi
if wt_local "$R16" merge no-such-task >/dev/null 2>&1; then
  fail "merge: 存在しない task なら die する"
else
  pass "merge: 存在しない task なら die する"
fi
# 本体の tracked ファイルが dirty なら中断する
printf 'dirty\n' >>"$R16/result.txt"
out="$(wt_local "$W16" merge 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '未コミット'; then
  pass "merge: 本体の tracked dirty で中断する"
else
  fail "merge: 本体の tracked dirty で中断する (rc=$rc out=$out)"
fi
git -C "$R16" checkout -q -- result.txt
# 本体に untracked ファイルがあっても成功する (-uno の検証。.claude/worktrees が常に untracked のため)
printf 'x\n' >"$R16/untracked.txt"
if wt_local "$W16" merge >/dev/null 2>&1; then
  pass "merge: 本体の untracked のみなら成功する"
else
  fail "merge: 本体の untracked のみなら成功する"
fi

# --- test 18: merge のコンフリクトは auto-abort せず本体に残す ---
R18="$TMP/repo18"
new_repo "$R18"
printf 'base\n' >"$R18/f.txt"
git -C "$R18" add f.txt
git -C "$R18" commit -qm base
wt_local "$R18" new m18 --no-claude >/dev/null 2>&1
W18="$R18/.claude/worktrees/m18"
printf 'from-worktree\n' >"$W18/f.txt"
git -C "$W18" commit -qam wt-side
printf 'from-main\n' >"$R18/f.txt"
git -C "$R18" commit -qam main-side
if wt_local "$W18" merge >/dev/null 2>&1; then
  fail "merge: コンフリクトで非 0 になる"
else
  pass "merge: コンフリクトで非 0 になる"
fi
conflicts="$(git -C "$R18" diff --name-only --diff-filter=U)"
assert_eq "merge: コンフリクトを auto-abort せず本体に残す" "f.txt" "$conflicts"
git -C "$R18" merge --abort >/dev/null 2>&1

# --- test 19: rm は worktree 内から task 省略で自己削除できる (git フォールバック経路) ---
R19="$TMP/repo19"
new_repo "$R19"
wt_local "$R19" new s19 --no-claude >/dev/null 2>&1
W19="$R19/.claude/worktrees/s19"
if wt_local "$W19" rm >/dev/null 2>&1; then
  pass "rm: worktree 内から task 省略で自己削除できる"
else
  fail "rm: worktree 内から task 省略で自己削除できる"
fi
assert_no_dir "$W19" "rm: 自己削除で worktree が消える"
if has_branch "$R19" "worktree-s19"; then
  fail "rm: 自己削除でブランチも消える"
else
  pass "rm: 自己削除でブランチも消える"
fi

# --- test 20: rm は本体で task 省略なら die する ---
out="$(wt_local "$R19" rm 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'task を指定'; then
  pass "rm: 本体で task 省略なら die する"
else
  fail "rm: 本体で task 省略なら die する (rc=$rc out=$out)"
fi

# --- test 21: fake herdr で claude の起動 argv とプロンプト投入を検証する ---
# 新しい herdr API では実行ファイルを argv で渡さず、agent start <name>
# --kind claude --pane <root pane> -- <claude の引数> で起動する。
# 既定で --model opus --permission-mode auto が入る。
# プロンプトは argv では渡さない: herdr 0.8 は agent 引数に改行を通せない
# (invalid_agent_argument) ため、起動後に agent prompt で 1 要素として投げる。
# WT_CLAUDE_ARGS でフラグを差し替えられ、空文字ならフラグ無しになる。
if [ -x /usr/bin/jq ]; then
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
# テスト用 herdr スタブ。worktree create は実際に git worktree を作り、
# workspace / root pane を返す。agent start は受け取った argv 全体を
# 1 行 1 要素で HERDR_ARGV_LOG に記録する。
set -euo pipefail
cmd="${1:-} ${2:-}"
case "$cmd" in
  "--version"*)
    printf 'herdr %s\n' "${HERDR_STUB_VERSION:-0.8.0}"
    exit 0
    ;;
  "workspace list") exit 0 ;;
  "worktree create")
    shift 2
    cwd="" branch="" base="" path=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd) cwd="$2"; shift ;;
        --branch) branch="$2"; shift ;;
        --base) base="$2"; shift ;;
        --path) path="$2"; shift ;;
        --label) shift ;;
      esac
      shift
    done
    git -C "$cwd" worktree add -q -b "$branch" "$path" "$base" >&2
    printf '{"result":{"workspace":{"workspace_id":"ws-stub"},"root_pane":{"pane_id":"ws-stub:p1"},"worktree":{"path":"%s"}}}\n' "$path"
    ;;
  "agent start")
    shift 2
    : >"$HERDR_ARGV_LOG"
    for a in "$@"; do printf '%s\n' "$a" >>"$HERDR_ARGV_LOG"; done
    ;;
  "agent prompt")
    shift 2
    if [ "${HERDR_STUB_PROMPT_FAIL:-0}" = "1" ]; then
      printf '{"error":{"code":"agent_not_found"}}\n'
      exit 1
    fi
    # 宛先と本文を別ファイルに分けて、本文の改行をそのまま保存する
    printf '%s\n' "$1" >"$HERDR_PROMPT_LOG.target"
    printf '%s' "$2" >"$HERDR_PROMPT_LOG.text"
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TMP/bin/herdr"
  # ログから herdr agent start のオプション部 / -- 以降の claude 引数を取り出す
  herdr_opts_of() { awk '$0=="--"{exit} {print}' "$1" 2>/dev/null; }
  claude_args_of() { awk 'f{print} $0=="--"{f=1}' "$1" 2>/dev/null; }

  R21="$TMP/repo21"
  new_repo "$R21"
  LOG21="$TMP/agent-argv.log"
  PLOG21="$TMP/agent-prompt"
  (cd "$R21" && env -u WT_HOME -u WT_CLAUDE_ARGS HOME="$TMP/home" HERDR_ARGV_LOG="$LOG21" \
    HERDR_PROMPT_LOG="$PLOG21" \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new p21 --prompt "hello world") >/dev/null 2>&1
  assert_eq "stub: agent start は名前 + --kind claude + worktree の root pane を渡す" \
    "claude-p21 --kind claude --pane ws-stub:p1" "$(herdr_opts_of "$LOG21" | paste -sd' ' -)"
  argc="$(claude_args_of "$LOG21" | wc -l | tr -d ' ')"
  assert_eq "stub: claude 引数は -n + 既定フラグの 6 要素 (prompt を含まない)" "6" "$argc"
  assert_eq "stub: 実行ファイル名は argv に含めず --kind に委ねる" \
    "0" "$(claude_args_of "$LOG21" | grep -c '^claude$')"
  assert_eq "stub: セッション名を -n wt-<task> に固定する" \
    "-n wt-p21" "$(claude_args_of "$LOG21" | sed -n 1,2p | paste -sd' ' -)"
  assert_eq "stub: 既定フラグが --model opus --permission-mode auto" \
    "--model opus --permission-mode auto" "$(claude_args_of "$LOG21" | sed -n 3,6p | paste -sd' ' -)"
  assert_eq "stub: prompt を agent start の argv に載せない" \
    "0" "$(claude_args_of "$LOG21" | grep -c 'hello world')"
  assert_eq "stub: agent prompt の宛先が agent 名 claude-<task>" \
    "claude-p21" "$(cat "$PLOG21.target" 2>/dev/null)"
  assert_eq "stub: agent prompt の本文が prompt 全体" \
    "hello world" "$(cat "$PLOG21.text" 2>/dev/null)"

  # 改行入りプロンプト: argv 経路は herdr が invalid_agent_argument で拒むので、
  # agent prompt に 1 要素で渡し、本文をバイト単位で保つ (畳まない)。
  LOG21E="$TMP/agent-argv-e.log"
  PLOG21E="$TMP/agent-prompt-e"
  ML21="$TMP/prompt-multiline.txt"
  printf '%s' '1 行目: 調査から始める
- 箇条書き 1
- 箇条書き 2

## 見出し
最終行' >"$ML21"
  (cd "$R21" && env -u WT_HOME -u WT_CLAUDE_ARGS HOME="$TMP/home" HERDR_ARGV_LOG="$LOG21E" \
    HERDR_PROMPT_LOG="$PLOG21E" \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new p21e --prompt-file "$ML21") >/dev/null 2>&1
  assert_eq "stub: 改行入り prompt でも agent start の argv は 6 要素のまま" \
    "6" "$(claude_args_of "$LOG21E" | wc -l | tr -d ' ')"
  if cmp -s "$ML21" "$PLOG21E.text"; then
    pass "stub: 改行入り prompt が agent prompt に原文のまま渡る"
  else
    fail "stub: 改行入り prompt が agent prompt に原文のまま渡る (got=$(cat "$PLOG21E.text" 2>/dev/null))"
  fi

  # agent prompt が失敗したらプロンプトを黙って落とさず die する
  LOG21F="$TMP/agent-argv-f.log"
  PLOG21F="$TMP/agent-prompt-f"
  out="$(cd "$R21" && env -u WT_HOME -u WT_CLAUDE_ARGS HOME="$TMP/home" HERDR_ARGV_LOG="$LOG21F" \
    HERDR_PROMPT_LOG="$PLOG21F" HERDR_STUB_PROMPT_FAIL=1 \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new p21f --prompt "hi" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'herdr agent prompt'; then
    pass "stub: agent prompt 失敗時は die して再投入コマンドを案内する"
  else
    fail "stub: agent prompt 失敗時は die して再投入コマンドを案内する (rc=$rc out=$out)"
  fi

  # WT_CLAUDE_ARGS でフラグを差し替える (-n は残る)
  LOG21B="$TMP/agent-argv-b.log"
  (cd "$R21" && env -u WT_HOME HOME="$TMP/home" HERDR_ARGV_LOG="$LOG21B" \
    HERDR_PROMPT_LOG="$TMP/agent-prompt-b" WT_CLAUDE_ARGS="--model sonnet" \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new p21b --prompt "hi") >/dev/null 2>&1
  assert_eq "stub: WT_CLAUDE_ARGS でフラグを差し替えられる" \
    "-n wt-p21b --model sonnet" "$(claude_args_of "$LOG21B" | paste -sd' ' -)"

  # WT_CLAUDE_ARGS="" (空文字) でフラグ無し (-n は残る)
  LOG21C="$TMP/agent-argv-c.log"
  (cd "$R21" && env -u WT_HOME HOME="$TMP/home" HERDR_ARGV_LOG="$LOG21C" \
    HERDR_PROMPT_LOG="$TMP/agent-prompt-c" WT_CLAUDE_ARGS="" \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new p21c --prompt "hi") >/dev/null 2>&1
  assert_eq "stub: WT_CLAUDE_ARGS 空文字でもセッション名は付く" \
    "-n wt-p21c" "$(claude_args_of "$LOG21C" | paste -sd' ' -)"

  # WT_CLAUDE_ARGS の -n は既定名より後ろに置かれ、claude 側で後勝ちになる
  LOG21D="$TMP/agent-argv-d.log"
  (cd "$R21" && env -u WT_HOME HOME="$TMP/home" HERDR_ARGV_LOG="$LOG21D" \
    HERDR_PROMPT_LOG="$TMP/agent-prompt-d" WT_CLAUDE_ARGS="-n custom" \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new p21d --prompt "hi") >/dev/null 2>&1
  assert_eq "stub: WT_CLAUDE_ARGS の -n が既定名より後に来る" \
    "-n wt-p21d -n custom" "$(claude_args_of "$LOG21D" | paste -sd' ' -)"
else
  pass "stub: jq が無いためスキップ"
fi

# --- test 22: install.sh は skills を ~/.claude/skills に配置する ---
INSTALL="$(dirname "$WT")/install.sh"
H22="$TMP/home22"
mkdir -p "$H22"
env HOME="$H22" PREFIX="$TMP/bin22" PATH="$SAFE_PATH" bash "$INSTALL" >/dev/null 2>&1
ok22=1
for s in worktree-parallel wt wt-detail wt-review wt-merge wt-clean wt-ask local-artifact; do
  [ -f "$H22/.claude/skills/$s/SKILL.md" ] || ok22=0
done
if [ "$ok22" -eq 1 ]; then
  pass "install: skills 8 個を ~/.claude/skills に配置する"
else
  fail "install: skills 8 個を ~/.claude/skills に配置する"
fi
# SKILL.md 以外の同梱物も配置される (wt-review はテンプレートと render.py が無いと動かない)。
assert_file "$H22/.claude/skills/wt-review/assets/render.py" \
  "install: wt-review の assets も配置する"
assert_file "$H22/.claude/skills/wt-review/assets/wt-review-template.html" \
  "install: wt-review のテンプレートも配置する"
# repo から消えたファイルが残らないよう skill ディレクトリは毎回作り直す。
: > "$H22/.claude/skills/wt-review/stale.md"
env HOME="$H22" PREFIX="$TMP/bin22" PATH="$SAFE_PATH" bash "$INSTALL" >/dev/null 2>&1
if [ -e "$H22/.claude/skills/wt-review/stale.md" ]; then
  fail "install: 再実行で古いファイルを残さない"
else
  pass "install: 再実行で古いファイルを残さない"
fi
H22B="$TMP/home22b"
mkdir -p "$H22B"
env HOME="$H22B" PREFIX="$TMP/bin22" PATH="$SAFE_PATH" WT_INSTALL_SKILLS=0 bash "$INSTALL" >/dev/null 2>&1
assert_no_dir "$H22B/.claude/skills" "install: WT_INSTALL_SKILLS=0 で skills を配置しない"

# --- test 23: merge は worktree の scripts/check を実行してからマージする ---
R23="$TMP/repo23"
new_repo "$R23"
mkdir -p "$R23/scripts"
cat >"$R23/scripts/check" <<CHK
#!/usr/bin/env bash
pwd -P >"$TMP/check23.log"
CHK
chmod +x "$R23/scripts/check"
git -C "$R23" add scripts/check
git -C "$R23" commit -qm check
wt_local "$R23" new g23 --no-claude >/dev/null 2>&1
W23="$R23/.claude/worktrees/g23"
printf 'done\n' >"$W23/result.txt"
git -C "$W23" add result.txt
git -C "$W23" commit -qm result
if wt_local "$W23" merge >/dev/null 2>&1; then
  pass "merge: scripts/check 成功でマージする"
else
  fail "merge: scripts/check 成功でマージする"
fi
assert_file "$R23/result.txt" "merge: check 成功後にコミットが本体へ入る"
assert_eq "merge: check は worktree を cwd に実行される" \
  "$(cd "$W23" && pwd -P)" "$(cat "$TMP/check23.log" 2>/dev/null)"

# --- test 24: scripts/check が失敗したらマージしない ---
R24="$TMP/repo24"
new_repo "$R24"
mkdir -p "$R24/scripts"
cat >"$R24/scripts/check" <<CHK
#!/usr/bin/env bash
: >"$TMP/check24.log"
exit 1
CHK
chmod +x "$R24/scripts/check"
git -C "$R24" add scripts/check
git -C "$R24" commit -qm check
wt_local "$R24" new g24 --no-claude >/dev/null 2>&1
W24="$R24/.claude/worktrees/g24"
printf 'x\n' >"$W24/f.txt"
git -C "$W24" add f.txt
git -C "$W24" commit -qm add-f
out="$(wt_local "$W24" merge 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'check'; then
  pass "merge: check 失敗で中断する"
else
  fail "merge: check 失敗で中断する (rc=$rc out=$out)"
fi
if [ -f "$R24/f.txt" ]; then
  fail "merge: check 失敗ではマージ自体を開始しない"
else
  pass "merge: check 失敗ではマージ自体を開始しない"
fi
if git -C "$R24" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  fail "merge: check 失敗で merge in progress を残さない"
else
  pass "merge: check 失敗で merge in progress を残さない"
fi

# --- test 25: --no-check は check を実行せずマージする ---
rm -f "$TMP/check24.log"
if wt_local "$W24" merge --no-check >/dev/null 2>&1; then
  pass "merge: --no-check でマージできる"
else
  fail "merge: --no-check でマージできる"
fi
assert_file "$R24/f.txt" "merge: --no-check でコミットが本体へ入る"
if [ -e "$TMP/check24.log" ]; then
  fail "merge: --no-check では check を実行しない"
else
  pass "merge: --no-check では check を実行しない"
fi

# --- test 26: scripts/check が無ければ警告してマージは通す ---
R26="$TMP/repo26"
new_repo "$R26"
wt_local "$R26" new g26 --no-claude >/dev/null 2>&1
W26="$R26/.claude/worktrees/g26"
printf 'y\n' >"$W26/g.txt"
git -C "$W26" add g.txt
git -C "$W26" commit -qm add-g
out="$(wt_local "$W26" merge 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'スキップ'; then
  pass "merge: check 無しは警告してマージを通す"
else
  fail "merge: check 無しは警告してマージを通す (rc=$rc out=$out)"
fi
# ブランチだけ残して worktree が無い場合もスキップ扱いで通す
R26B="$TMP/repo26b"
new_repo "$R26B"
wt_local "$R26B" new g26b --no-claude >/dev/null 2>&1
W26B="$R26B/.claude/worktrees/g26b"
printf 'z\n' >"$W26B/h.txt"
git -C "$W26B" add h.txt
git -C "$W26B" commit -qm add-h
git -C "$R26B" worktree remove --force "$W26B" >/dev/null 2>&1
out="$(wt_local "$R26B" merge g26b 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'worktree が無いため'; then
  pass "merge: worktree 無し (ブランチのみ) もスキップ警告で通す"
else
  fail "merge: worktree 無し (ブランチのみ) もスキップ警告で通す (rc=$rc out=$out)"
fi
# 実行 bit の無い scripts/check は専用の警告でスキップして通す
R26C="$TMP/repo26c"
new_repo "$R26C"
mkdir -p "$R26C/scripts"
printf '#!/usr/bin/env bash\nexit 1\n' >"$R26C/scripts/check"
git -C "$R26C" add scripts/check
git -C "$R26C" commit -qm check
wt_local "$R26C" new g26c --no-claude >/dev/null 2>&1
W26C="$R26C/.claude/worktrees/g26c"
printf 'w\n' >"$W26C/i.txt"
git -C "$W26C" add i.txt
git -C "$W26C" commit -qm add-i
chmod -x "$W26C/scripts/check"
out="$(wt_local "$W26C" merge 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '実行可能でない'; then
  pass "merge: 非実行可能な check は専用警告でスキップして通す"
else
  fail "merge: 非実行可能な check は専用警告でスキップして通す (rc=$rc out=$out)"
fi

# --- test 27: パスに空白を含む repo でもゲートと rm が機能する (fail-open 回帰防止) ---
R27="$TMP/repo 27"
new_repo "$R27"
mkdir -p "$R27/scripts"
printf '#!/usr/bin/env bash\nexit 1\n' >"$R27/scripts/check"
chmod +x "$R27/scripts/check"
git -C "$R27" add scripts/check
git -C "$R27" commit -qm check
wt_local "$R27" new g27 --no-claude >/dev/null 2>&1
W27="$R27/.claude/worktrees/g27"
printf 'x\n' >"$W27/f.txt"
git -C "$W27" add f.txt
git -C "$W27" commit -qm add-f
if wt_local "$W27" merge >/dev/null 2>&1; then
  fail "merge: 空白入りパスでも check 失敗で中断する"
else
  pass "merge: 空白入りパスでも check 失敗で中断する"
fi
if [ -f "$R27/f.txt" ]; then
  fail "merge: 空白入りパスでマージ自体を開始しない"
else
  pass "merge: 空白入りパスでマージ自体を開始しない"
fi
if wt_local "$R27" rm g27 --force >/dev/null 2>&1; then
  pass "rm: 空白入りパスの worktree を削除できる"
else
  fail "rm: 空白入りパスの worktree を削除できる"
fi
assert_no_dir "$W27" "rm: 空白入りパスで worktree が消える"

# --- test 28: merge のオプションエラー ---
out="$(wt_local "$R26" merge --bogus 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '不明なオプション'; then
  pass "merge: 不明なオプションを弾く"
else
  fail "merge: 不明なオプションを弾く (rc=$rc out=$out)"
fi
out="$(wt_local "$R26" merge aa bb 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '引数が多すぎる'; then
  pass "merge: 引数が多すぎる場合は中断する"
else
  fail "merge: 引数が多すぎる場合は中断する (rc=$rc out=$out)"
fi

# --- test 29: peers は repo 内の生存セッションを role 付きで列挙する ---
# Claude Code のセッションレジストリ (<config>/sessions/<pid>.json) を偽装して検証する。
if [ -x /usr/bin/jq ]; then
  R29="$TMP/repo29"
  new_repo "$R29"
  wt_local "$R29" new p29 --no-claude >/dev/null 2>&1
  W29="$R29/.claude/worktrees/p29"
  mkdir -p "$W29/sub" "$TMP/home/.claude/sessions" "$TMP/outside"

  # 生存 pid を確保する (他セッションの見立て)
  sleep 300 &
  A29=$!
  sleep 300 &
  B29=$!
  sleep 300 &
  C29=$!
  # 確実に死んでいる pid
  sleep 0 &
  D29=$!
  wait "$D29" 2>/dev/null

  reg29() { # pid cwd name
    printf '{"pid":%s,"cwd":"%s","name":"%s","kind":"interactive","status":"idle"}\n' \
      "$1" "$2" "$3" >"$TMP/home/.claude/sessions/$1.json"
  }
  reg29 "$$" "$R29" "dev-session"        # テスト自身は wt の祖先 → (self) が付く
  reg29 "$A29" "$W29" "wt-p29"
  reg29 "$B29" "$W29/sub" "wt-p29-deep"  # worktree のサブディレクトリ
  reg29 "$C29" "$TMP/outside" "outsider" # repo 外
  reg29 "$D29" "$R29" "dead-session"     # 死んだ pid

  peers29() { # cwd args...
    local d="$1"
    shift
    (cd "$d" && env -u WT_HOME -u CLAUDE_CONFIG_DIR HOME="$TMP/home" PATH="$SAFE_PATH" "$WT" peers "$@")
  }
  out29="$(peers29 "$R29" --json 2>/dev/null)"
  peer_field() { printf '%s' "$out29" | jq -r ".[] | select(.name==\"$1\") | .$2"; }
  assert_eq "peers: repo 内の生存セッションだけを返す" "3" "$(printf '%s' "$out29" | jq 'length')"
  assert_eq "peers: 本体 checkout は role=dev" "dev" "$(peer_field dev-session role)"
  assert_eq "peers: worktree は role=<task>" "p29" "$(peer_field wt-p29 role)"
  assert_eq "peers: worktree のサブディレクトリも worktree に分類する" "p29" "$(peer_field wt-p29-deep role)"
  assert_eq "peers: 自分の行は self=true" "true" "$(peer_field dev-session self)"
  assert_eq "peers: 他セッションは self=false" "false" "$(peer_field wt-p29 self)"
  assert_eq "peers: 死んだセッションを除外する" "" "$(peer_field dead-session name)"
  assert_eq "peers: repo 外のセッションを除外する" "" "$(peer_field outsider name)"
  assert_eq "peers: worktree 内から実行しても本体セッションが見える" "dev" \
    "$(peers29 "$W29" --json 2>/dev/null | jq -r '.[] | select(.name=="dev-session") | .role')"

  # pipefail 下で `peers29 | grep -q` は grep の早期終了で wt が SIGPIPE を受け、
  # パイプライン全体が非 0 になる。判定は変数に取ってから行う。
  txt29="$(peers29 "$R29" 2>&1)"
  if printf '%s' "$txt29" | grep -q '(self)'; then
    pass "peers: テキスト出力に (self) を付ける"
  else
    fail "peers: テキスト出力に (self) を付ける (out=$txt29)"
  fi

  # CLAUDE_CONFIG_DIR を優先する
  mkdir -p "$TMP/altconfig/sessions"
  printf '{"pid":%s,"cwd":"%s","name":"alt-session","kind":"interactive","status":"idle"}\n' \
    "$$" "$R29" >"$TMP/altconfig/sessions/$$.json"
  alt29="$(cd "$R29" && env -u WT_HOME HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/altconfig" \
    PATH="$SAFE_PATH" "$WT" peers --json 2>/dev/null)"
  assert_eq "peers: CLAUDE_CONFIG_DIR のレジストリを見る" "alt-session" \
    "$(printf '%s' "$alt29" | jq -r '.[0].name')"

  # レジストリが無ければ中断する
  H29="$TMP/home29"
  mkdir -p "$H29"
  out="$(cd "$R29" && env -u WT_HOME -u CLAUDE_CONFIG_DIR HOME="$H29" PATH="$SAFE_PATH" "$WT" peers 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'レジストリ'; then
    pass "peers: セッションレジストリが無ければ中断する"
  else
    fail "peers: セッションレジストリが無ければ中断する (rc=$rc out=$out)"
  fi

  out="$(peers29 "$R29" --bogus 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '不明なオプション'; then
    pass "peers: 不明なオプションを弾く"
  else
    fail "peers: 不明なオプションを弾く (rc=$rc out=$out)"
  fi
  out="$(peers29 "$R29" extra 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '位置引数'; then
    pass "peers: 位置引数を弾く"
  else
    fail "peers: 位置引数を弾く (rc=$rc out=$out)"
  fi

  kill "$A29" "$B29" "$C29" 2>/dev/null
else
  pass "peers: jq が無いためスキップ"
fi

# --- test 30: herdr バージョン契約 (系列外は fail-fast、スキップ可、不明は通す) ---
# herdr は 0.x の間マイナー更新で CLI 契約が変わる実績があるため、wt は検証済み
# 系列 (HERDR_SERIES) 以外の herdr では黙って壊れる代わりに die する。
if [ -x /usr/bin/jq ] && [ -x "$TMP/bin/herdr" ]; then
  R30="$TMP/repo30"
  new_repo "$R30"
  out="$(cd "$R30" && env -u WT_HOME HOME="$TMP/home" HERDR_STUB_VERSION=0.9.0 \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new v30 --no-claude 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '未検証'; then
    pass "herdr契約: 系列外バージョンで die する"
  else
    fail "herdr契約: 系列外バージョンで die する (rc=$rc out=$out)"
  fi
  assert_no_dir "$R30/.claude/worktrees/v30" "herdr契約: die 時は worktree を作らない"
  if has_branch "$R30" "worktree-v30"; then
    fail "herdr契約: die 時はブランチも作らない"
  else
    pass "herdr契約: die 時はブランチも作らない"
  fi

  out="$(cd "$R30" && env -u WT_HOME HOME="$TMP/home" HERDR_STUB_VERSION=0.9.0 WT_HERDR_SKIP_CHECK=1 \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new v30b --no-claude 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '警告.*未検証'; then
    pass "herdr契約: WT_HERDR_SKIP_CHECK=1 で警告して続行する"
  else
    fail "herdr契約: WT_HERDR_SKIP_CHECK=1 で警告して続行する (rc=$rc out=$out)"
  fi
  assert_dir "$R30/.claude/worktrees/v30b" "herdr契約: スキップ時は worktree を作る"

  # バージョンを報告しない herdr は判定せず通す (fail-open。stub や旧版を殺さない)
  mkdir -p "$TMP/bin30c"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin30c/herdr"
  chmod +x "$TMP/bin30c/herdr"
  if (cd "$R30" && env -u WT_HOME HOME="$TMP/home" PATH="$TMP/bin30c:$SAFE_PATH" "$WT" list) >/dev/null 2>&1; then
    pass "herdr契約: バージョン不明の herdr は判定せず通す"
  else
    fail "herdr契約: バージョン不明の herdr は判定せず通す"
  fi
else
  pass "herdr契約: jq が無いためスキップ"
fi

# --- test 31: Claude Code plugin / marketplace の契約 ---
# マーケットプレイス配布の入口。壊れると /plugin marketplace add が黙って失敗するため、
# マニフェストの必須フィールドと、skill 名の安定性 (frontmatter name == ディレクトリ名) を固定する。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MKT="$REPO_ROOT/.claude-plugin/marketplace.json"
PLG="$REPO_ROOT/.claude-plugin/plugin.json"

assert_file "$MKT" "plugin: marketplace.json がある"
assert_file "$PLG" "plugin: plugin.json がある"

if command -v jq >/dev/null 2>&1; then
  if jq -e . "$MKT" >/dev/null 2>&1 && jq -e . "$PLG" >/dev/null 2>&1; then
    pass "plugin: マニフェストが妥当な JSON"
  else
    fail "plugin: マニフェストが妥当な JSON"
  fi
  assert_eq "plugin: marketplace 名は wt" "wt" "$(jq -r '.name // ""' "$MKT")"
  if [ -n "$(jq -r '.owner.name // ""' "$MKT")" ]; then
    pass "plugin: marketplace に owner.name がある"
  else
    fail "plugin: marketplace に owner.name がある"
  fi
  assert_eq "plugin: エントリは 1 件" "1" "$(jq -r '.plugins | length' "$MKT")"
  # source は marketplace root (= repo root) 自身。skills/ と bin/ をそのまま配る前提。
  assert_eq "plugin: source は repo root" "./" "$(jq -r '.plugins[0].source // ""' "$MKT")"
  # 名前が食い違うと install 後の skill namespace (/wt:wt-merge) がずれる。
  assert_eq "plugin: エントリ名と plugin.json の name が一致" \
    "$(jq -r '.name // ""' "$PLG")" "$(jq -r '.plugins[0].name // ""' "$MKT")"
  assert_eq "plugin: plugin 名は wt" "wt" "$(jq -r '.name // ""' "$PLG")"
else
  pass "plugin: jq が無いためマニフェスト検査をスキップ"
fi

# bin/ は plugin 有効時に Bash tool の PATH へ入る。本体へ委譲するだけの薄い wrapper。
if [ -x "$REPO_ROOT/bin/wt" ]; then
  pass "plugin: bin/wt が実行可能"
else
  fail "plugin: bin/wt が実行可能"
fi
assert_eq "plugin: bin/wt は本体と同じ usage を出す" \
  "$(env -u WT_HOME HOME="$TMP/home" PATH="$SAFE_PATH" "$WT" 2>&1 | head -1)" \
  "$(env -u WT_HOME HOME="$TMP/home" PATH="$SAFE_PATH" "$REPO_ROOT/bin/wt" 2>&1 | head -1)"

# plugin 更新でディレクトリ名が変わっても skill 名が動かないよう frontmatter name を正とする。
skill_name_mismatch=""
for d in "$REPO_ROOT/skills"/*/; do
  n="$(basename "$d")"
  fm="$(sed -n '/^name:[[:space:]]*/{s/^name:[[:space:]]*//p;q}' "$d/SKILL.md")"
  [ "$fm" = "$n" ] || skill_name_mismatch="$skill_name_mismatch $n(=$fm)"
done
assert_eq "plugin: 全 skill の frontmatter name がディレクトリ名と一致" "" "$skill_name_mismatch"

# --- test 32: render.py がレビューページを組み立てる ---
# /wt-review の生成資産。テンプレートのプレースホルダーが全部埋まること、
# 折りたたみ判定、節の出し分けを固定する。python3 が無い環境ではスキップする。
ASSETS="$REPO_ROOT/skills/wt-review/assets"
assert_file "$ASSETS/render.py" "render: render.py がある"
assert_file "$ASSETS/wt-review-template.html" "render: テンプレートがある"
assert_file "$ASSETS/sample-net.diff" "render: サンプル diff がある"
assert_file "$ASSETS/sample-summary.html" "render: サンプル要約断片がある"

if command -v python3 >/dev/null 2>&1; then
  R32="$TMP/render32"
  H32="$TMP/home32"
  mkdir -p "$R32" "$H32"
  # HOME を temp に向ける。mermaid キャッシュ (~/.cache/wt) を実ホームに作らせない。
  render32() { # out args...
    local out="$1"
    shift
    env HOME="$H32" python3 "$ASSETS/render.py" \
      --diff "$ASSETS/sample-net.diff" --out "$out" \
      --title "サンプル" --summary "$ASSETS/sample-summary.html" "$@" 2>"$R32/err.log"
  }

  out32="$R32/plain.html"
  log32="$(render32 "$out32")"
  assert_eq "render: 統計行がサンプルの実数と一致する" "files=4 +342 -3" \
    "$(printf '%s\n' "$log32" | head -1)"
  assert_file "$out32" "render: HTML を出力する"
  # プレースホルダーとマーカーは全部消費される (断片由来の HTML コメントは許す)。
  assert_eq "render: プレースホルダーを残さない" "0" "$(grep -c '<!--[A-Z]' "$out32")"
  assert_eq "render: --tests 省略なら「テスト結果」節を出さない" "0" \
    "$(grep -c 'テスト結果' "$out32")"
  assert_eq "render: 断片に mermaid が無ければ描画スクリプトを入れない" "0" \
    "$(grep -c 'mermaid' "$out32")"
  # 既定の閾値 200 行。print.css (+213/-0) だけが折りたたまれる。
  assert_eq "render: 既定は 200 行超だけ折りたたむ" "3" \
    "$(grep -c 'class="diff-file" open' "$out32")"

  # --collapse-threshold を下げると全ファイルが折りたたまれる (最小は README.md の 14 行)。
  render32 "$R32/tight.html" --collapse-threshold 10 >/dev/null
  assert_eq "render: --collapse-threshold で閾値を変えられる" "0" \
    "$(grep -c 'class="diff-file" open' "$R32/tight.html")"

  # 明示指定は閾値より強い。
  render32 "$R32/opened.html" --open styles/print.css >/dev/null
  assert_eq "render: --open は閾値超のファイルも開く" "4" \
    "$(grep -c 'class="diff-file" open' "$R32/opened.html")"
  render32 "$R32/collapsed.html" --collapse README.md >/dev/null
  assert_eq "render: --collapse は閾値内のファイルも折りたたむ" "2" \
    "$(grep -c 'class="diff-file" open' "$R32/collapsed.html")"

  # diff に無いパスを指定したら警告する (タイポ検知)。
  render32 "$R32/warn.html" --open no/such/path >/dev/null
  if grep -q 'no/such/path' "$R32/err.log"; then
    pass "render: diff に無いパスを --open したら警告する"
  else
    fail "render: diff に無いパスを --open したら警告する"
  fi

  # --tests を渡すと「テスト結果」節が出る。
  cat > "$R32/tests.html" <<'EOF'
<div class="test-stats">
  <div class="test-stat test-stat-done"><span class="num">1</span><span class="lbl">実施</span></div>
</div>
EOF
  render32 "$R32/withtests.html" --tests "$R32/tests.html" >/dev/null
  if grep -q 'テスト結果' "$R32/withtests.html"; then
    pass "render: --tests を渡すと「テスト結果」節が出る"
  else
    fail "render: --tests を渡すと「テスト結果」節が出る"
  fi
  assert_eq "render: --tests 指定でもプレースホルダーを残さない" "0" \
    "$(grep -c '<!--[A-Z]' "$R32/withtests.html")"

  # 断片に mermaid があればキャッシュから mermaid.min.js を置く (ネットワークに出ない)。
  mkdir -p "$H32/.cache/wt" "$R32/mm"
  printf '/* stub */\n' > "$H32/.cache/wt/mermaid.min.js"
  printf '<pre class="mermaid">graph LR; A-->B;</pre>\n' > "$R32/summary-mm.html"
  env HOME="$H32" python3 "$ASSETS/render.py" \
    --diff "$ASSETS/sample-net.diff" --out "$R32/mm/out.html" \
    --title "サンプル" --summary "$R32/summary-mm.html" >/dev/null 2>&1
  assert_file "$R32/mm/mermaid.min.js" "render: mermaid.min.js を出力先へ置く"
  if grep -q 'mermaid.min.js' "$R32/mm/out.html"; then
    pass "render: mermaid の描画スクリプトを入れる"
  else
    fail "render: mermaid の描画スクリプトを入れる"
  fi
  mkdir -p "$R32/nomm"
  env HOME="$H32" python3 "$ASSETS/render.py" --no-mermaid \
    --diff "$ASSETS/sample-net.diff" --out "$R32/nomm/out.html" \
    --title "サンプル" --summary "$R32/summary-mm.html" >/dev/null 2>&1
  assert_eq "render: --no-mermaid なら描画スクリプトを入れない" "0" \
    "$(grep -c 'mermaid.min.js' "$R32/nomm/out.html")"
  # キャッシュの中身がそのまま複製されている = 取得に出ていない。
  assert_eq "render: mermaid はキャッシュから複製する" "/* stub */" \
    "$(cat "$R32/mm/mermaid.min.js")"

  # 入力が無ければ書き込まずに落ちる。
  env HOME="$H32" python3 "$ASSETS/render.py" --diff "$R32/nope.diff" \
    --out "$R32/never.html" --title x --summary "$ASSETS/sample-summary.html" >/dev/null 2>&1
  assert_eq "render: 入力が無ければ exit 2" "2" "$?"
  if [ -f "$R32/never.html" ]; then
    fail "render: 失敗時は出力を書かない"
  else
    pass "render: 失敗時は出力を書かない"
  fi

  # git メタ情報とコミット一覧。--base を渡した経路。
  R32G="$TMP/repo32"
  new_repo "$R32G"
  git -C "$R32G" commit -q --allow-empty -m "レビュー対象のコミット"
  base32="$(git -C "$R32G" rev-parse HEAD~1)"
  (cd "$R32G" && env HOME="$H32" python3 "$ASSETS/render.py" \
    --diff "$ASSETS/sample-net.diff" --out "$R32/git.html" \
    --title "サンプル" --summary "$ASSETS/sample-summary.html" --base "$base32") >/dev/null 2>&1
  assert_eq "render: --base でメタ情報とコミット一覧を埋める" "0" \
    "$(grep -c '<!--[A-Z]' "$R32/git.html")"
  if grep -q 'Base SHA' "$R32/git.html" && grep -q 'レビュー対象のコミット' "$R32/git.html"; then
    pass "render: Base SHA とコミット件名を出す"
  else
    fail "render: Base SHA とコミット件名を出す"
  fi
  assert_eq "render: --base 省略時はコミット節を出さない" "0" \
    "$(grep -c 'class="commits"' "$out32")"

  # 承認ボタン。テンプレート同梱の固定資産なので、どの出力にも必ず入る。
  # 既定は hidden で、http 配信 + token のときだけ script が出す (file:// は degrade)。
  assert_eq "render: 承認ボタンを埋め込む" "1" "$(grep -c 'id="approve-btn"' "$out32")"
  assert_eq "render: 承認セクションは既定で hidden" "1" \
    "$(grep -c 'id="approve" class="approve" hidden' "$out32")"
  assert_eq "render: 承認は same-origin の POST /approve に送る" "1" \
    "$(grep -c "fetch('approve'" "$out32")"

  if python3 -m py_compile "$ASSETS/render.py" >/dev/null 2>&1; then
    pass "render: render.py が構文エラー無くコンパイルできる"
  else
    fail "render: render.py が構文エラー無くコンパイルできる"
  fi
  rm -rf "$ASSETS/__pycache__"
else
  pass "render: python3 が無いためスキップ"
fi

# --- test 33: browse はプラットフォームごとの開き方を吸収する ---
# skill 側に explorer.exe を直書きしないための入口。stub を PATH の先頭に置いて
# 優先順・渡す引数 (絶対パスに正規化) ・手段が無いときの失敗を固定する。
B33="$TMP/browse33"
mkdir -p "$B33/bin"
printf 'hello\n' >"$B33/page.html"
make_stub() { # name body
  cat >"$B33/bin/$1" <<EOF
#!/usr/bin/env bash
$2
EOF
  chmod +x "$B33/bin/$1"
}
browse33() { # args...
  (cd "$B33" && env HOME="$TMP/home" WT_TEST_LOG="$B33/log" \
    PATH="$B33/bin:$SAFE_PATH" "$WT" browse "$@")
}

# stub の本体は生成先で展開させるため、ここでは展開させない (単一引用符は意図的)。
# shellcheck disable=SC2016
make_stub wslview 'printf "wslview %s\n" "$1" >"$WT_TEST_LOG"'
# shellcheck disable=SC2016
make_stub xdg-open 'printf "xdg-open %s\n" "$1" >"$WT_TEST_LOG"'
browse33 page.html >/dev/null 2>&1
assert_eq "browse: wslview を優先し絶対パスを渡す" "wslview $B33/page.html" \
  "$(cat "$B33/log" 2>/dev/null)"

# http(s) URL はファイルとして解決せず、そのまま opener に渡す (wt serve の出力)。
rm -f "$B33/log"
browse33 "http://localhost:12345/?token=abc" >/dev/null 2>&1
assert_eq "browse: http URL はそのまま opener に渡す" \
  "wslview http://localhost:12345/?token=abc" "$(cat "$B33/log" 2>/dev/null)"

# WSL で wslview が無いとき、URL は explorer.exe ではなく rundll32 に渡す
# (explorer.exe は URL を開けず、rc=1 で何も起きないため)。
mv "$B33/bin/wslview" "$B33/wslview.bak"
# shellcheck disable=SC2016
make_stub explorer.exe 'printf "explorer %s\n" "$1" >"$WT_TEST_LOG"'
# shellcheck disable=SC2016
make_stub wslpath 'printf "%s" "C:\\fake"'
# shellcheck disable=SC2016
make_stub rundll32.exe 'printf "rundll32 %s %s\n" "$1" "$2" >"$WT_TEST_LOG"'
rm -f "$B33/log"
browse33 "http://localhost:12345/?token=abc" >/dev/null 2>&1
assert_eq "browse: URL は rundll32 の FileProtocolHandler に渡す" \
  "rundll32 url.dll,FileProtocolHandler http://localhost:12345/?token=abc" \
  "$(cat "$B33/log" 2>/dev/null)"
# ローカルファイルは従来どおり explorer.exe (wslpath で Windows パスに変換)。
rm -f "$B33/log"
browse33 page.html >/dev/null 2>&1
assert_eq "browse: ファイルは explorer.exe に Windows パスで渡す" 'explorer C:\fake' \
  "$(cat "$B33/log" 2>/dev/null)"
# URL で rundll32 が無ければ explorer.exe を使わず次の手段に落ちる。
rm -f "$B33/bin/rundll32.exe" "$B33/log"
browse33 "http://localhost:12345/?token=abc" >/dev/null 2>&1
assert_eq "browse: URL に explorer.exe は使わない" \
  "xdg-open http://localhost:12345/?token=abc" "$(cat "$B33/log" 2>/dev/null)"
rm -f "$B33/bin/explorer.exe" "$B33/bin/wslpath"
mv "$B33/wslview.bak" "$B33/bin/wslview"

# wslview が使えなければ次の手段に落ちる。
rm -f "$B33/bin/wslview" "$B33/log"
browse33 page.html >/dev/null 2>&1
assert_eq "browse: wslview が無ければ xdg-open に落ちる" "xdg-open $B33/page.html" \
  "$(cat "$B33/log" 2>/dev/null)"

# どの手段も失敗したらパスを添えて die する (勝手に成功扱いしない)。
make_stub wslview 'exit 4'
make_stub open 'exit 5'
make_stub xdg-open 'exit 3'
out33="$(browse33 page.html 2>&1)"
rc33=$?
if [ "$rc33" -ne 0 ] && printf '%s' "$out33" | grep -q '開く手段が見つからない'; then
  pass "browse: 開く手段が無ければパスを添えて中断する"
else
  fail "browse: 開く手段が無ければパスを添えて中断する (rc=$rc33 out=$out33)"
fi

# 引数の検査。
out33="$(browse33 no-such-file.html 2>&1)"
rc33=$?
if [ "$rc33" -ne 0 ] && printf '%s' "$out33" | grep -q 'ファイルが無い'; then
  pass "browse: 存在しないパスを弾く"
else
  fail "browse: 存在しないパスを弾く (rc=$rc33 out=$out33)"
fi
if browse33 >/dev/null 2>&1; then
  fail "browse: パス省略は usage で中断する"
else
  pass "browse: パス省略は usage で中断する"
fi

# --- test 34: repo 内に worktree を作る構成では .gitignore の案内を出す ---
# 置き場は本体の git status に未追跡として出る。README の既知の注意点にも書いてあるが、
# 実行時に案内しないと気づかれないため wt new が知らせる。書き換えは利用者に委ねる。
R34="$TMP/repo34"
new_repo "$R34"
out34="$(wt_local "$R34" new g1 --no-claude 2>&1)"
if printf '%s' "$out34" | grep -q 'gitignore'; then
  pass "gitignore案内: 未追跡のままなら案内する"
else
  fail "gitignore案内: 未追跡のままなら案内する (out=$out34)"
fi

printf '.claude/worktrees/\n' >"$R34/.gitignore"
git -C "$R34" add .gitignore
git -C "$R34" commit -q -m "ignore worktrees"
out34b="$(wt_local "$R34" new g2 --no-claude 2>&1)"
if printf '%s' "$out34b" | grep -q 'gitignore'; then
  fail "gitignore案内: 無視済みなら案内しない (out=$out34b)"
else
  pass "gitignore案内: 無視済みなら案内しない"
fi

# WT_HOME で repo 外に作る構成では未追跡にならないので案内しない。
R34C="$TMP/repo34c"
new_repo "$R34C"
out34c="$(cd "$R34C" && HOME="$TMP/home" PATH="$SAFE_PATH" WT_HOME="$TMP/wthome34" "$WT" new g3 --no-claude 2>&1)"
if printf '%s' "$out34c" | grep -q 'gitignore'; then
  fail "gitignore案内: repo 外に作る構成では案内しない (out=$out34c)"
else
  pass "gitignore案内: repo 外に作る構成では案内しない"
fi

# --- test 35: serve は使い捨て HTTP サーバで配信し、承認を herdr に変換する ---
# /wt-review の承認ボタンの土台。token による絞り込み、リクエストごとの読み直し
# (再レビューはリロードで最新化)、承認 1 回での自己終了を固定する。
# python3 が無い環境ではスキップする。
PY35="$REPO_ROOT/wt-review-serve.py"
assert_file "$PY35" "serve: wt-review-serve.py が wt と同じディレクトリにある"
if command -v python3 >/dev/null 2>&1; then
  S35="$TMP/serve35"
  H35="$TMP/home35"
  R35="$TMP/repo35"
  mkdir -p "$S35/bin" "$S35/page" "$H35"
  new_repo "$R35"
  printf '<!doctype html><title>t</title><p>REVIEW-MARKER-1</p>\n' >"$S35/page/review.html"
  printf '/* mm-stub */\n' >"$S35/page/mermaid.min.js"

  # herdr スタブ。workspace list は成功し、agent prompt は宛先と本文を記録する。
  cat >"$S35/bin/herdr" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "--version"*) printf 'herdr 0.8.0\n' ;;
  "workspace list") exit 0 ;;
  "agent prompt")
    shift 2
    if [ "${HERDR_STUB_PROMPT_FAIL:-0}" = "1" ]; then
      printf 'agent_not_found\n' >&2
      exit 1
    fi
    printf '%s\n' "$1" >"$HERDR_PROMPT_LOG.target"
    printf '%s' "$2" >"$HERDR_PROMPT_LOG.text"
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$S35/bin/herdr"

  serve35() { # args...
    (cd "$R35" && env -u WT_HOME HOME="$H35" HERDR_PROMPT_LOG="$S35/prompt" \
      PATH="$S35/bin:$SAFE_PATH" "$WT" serve "$@")
  }
  wt35() { # args... (herdr 無しの経路)
    (cd "$R35" && env -u WT_HOME HOME="$H35" PATH="$SAFE_PATH" "$WT" "$@")
  }
  # 配信中の state (pid / port / token / url)。停止の確認に使う。
  state35() {
    find "$H35/.cache/wt/serve" -maxdepth 1 -name '*.state' 2>/dev/null | head -1
  }
  # PATH を絞っているので HTTP クライアントも python3 で用意する。
  # 出力は 1 行目が status (接続できなければ no-listener)、以降が body。
  http35() { # method url [json-body] [origin]
    python3 - "$@" <<'PY'
import sys, urllib.error, urllib.request
method, url = sys.argv[1], sys.argv[2]
data = sys.argv[3].encode() if len(sys.argv) > 3 and sys.argv[3] else None
req = urllib.request.Request(url, data=data, method=method)
if data is not None:
    req.add_header("Content-Type", "application/json")
if len(sys.argv) > 4 and sys.argv[4]:
    req.add_header("Origin", sys.argv[4])
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        print(r.status)
        sys.stdout.write(r.read().decode("utf-8", "replace"))
except urllib.error.HTTPError as e:
    print(e.code)
    sys.stdout.write(e.read().decode("utf-8", "replace"))
except OSError as e:
    print("no-listener")
    sys.stdout.write(str(e))
PY
  }

  url35="$(serve35 "$S35/page/review.html" --task s35 2>"$S35/serve.err" | grep -m1 '^http' || true)"
  case "$url35" in
    http://localhost:*/\?token=?*)
      pass "serve: localhost の URL を token 付きで stdout に 1 行出す"
      ;;
    *)
      fail "serve: localhost の URL を token 付きで stdout に 1 行出す (url=$url35 err=$(cat "$S35/serve.err" 2>/dev/null))"
      ;;
  esac

  if [ -n "$url35" ]; then
    base35="${url35%%\?*}"
    token35="${url35#*token=}"
    got35="$(http35 GET "$url35")"
    assert_eq "serve: token 付き GET はレビューページを返す" "200" \
      "$(printf '%s\n' "$got35" | head -1)"
    if printf '%s' "$got35" | grep -q 'REVIEW-MARKER-1'; then
      pass "serve: 配信するのは指定した HTML"
    else
      fail "serve: 配信するのは指定した HTML (got=$got35)"
    fi

    # token 無し / 不一致は拒否する (他所のページからの読み出し・drive-by 対策)。
    assert_eq "serve: token 無しの GET は 403" "403" "$(http35 GET "$base35" | head -1)"
    assert_eq "serve: token 不一致の GET は 403" "403" \
      "$(http35 GET "${base35}?token=wrong" | head -1)"

    # allowlist のアセットは token 無しで返す (script src は query を引き継げない)。
    assert_eq "serve: mermaid.min.js は token 無しで返す" "200" \
      "$(http35 GET "${base35}mermaid.min.js" | head -1)"
    assert_eq "serve: allowlist 外の同ディレクトリのファイルは 404" "404" \
      "$(http35 GET "${base35}review.html" | head -1)"

    # 再レビュー: 同じパスへの上書きがリロードだけで反映される。
    printf '<!doctype html><title>t</title><p>REVIEW-MARKER-2</p>\n' >"$S35/page/review.html"
    if http35 GET "$url35" | grep -q 'REVIEW-MARKER-2'; then
      pass "serve: HTML はリクエストごとに読み直す"
    else
      fail "serve: HTML はリクエストごとに読み直す"
    fi

    # 再実行では listener を増やさず同じ URL を返す。
    url35b="$(serve35 "$S35/page/review.html" --task s35 2>/dev/null | grep -m1 '^http' || true)"
    assert_eq "serve: 配信中なら同じ URL を再利用する" "$url35" "$url35b"

    # token 不一致の POST は 403。承認は投入されない。
    assert_eq "serve: token 不一致の POST は 403" "403" \
      "$(http35 POST "${base35}approve" '{"token":"wrong"}' | head -1)"
    if [ -f "$S35/prompt.target" ]; then
      fail "serve: token 不一致の POST では承認を投入しない"
    else
      pass "serve: token 不一致の POST では承認を投入しない"
    fi
    # token を知っていても別オリジンを名乗る POST は落とす。
    assert_eq "serve: 別オリジンからの POST は 403" "403" \
      "$(http35 POST "${base35}approve" "{\"token\":\"$token35\"}" "http://evil.example" | head -1)"

    # 正しい token の POST が herdr agent prompt に変換される。
    out35="$(http35 POST "${base35}approve" "{\"token\":\"$token35\"}")"
    assert_eq "serve: token 付きの POST /approve は 200" "200" \
      "$(printf '%s\n' "$out35" | head -1)"
    assert_eq "serve: 承認の宛先は claude-<task>" "claude-s35" \
      "$(cat "$S35/prompt.target" 2>/dev/null)"
    assert_eq "serve: 承認の本文は承認文そのもの" "承認します。/wt-merge に進んでください" \
      "$(cat "$S35/prompt.text" 2>/dev/null)"

    # 承認は 1 回きり。応答後に自分で終了し state も消える。
    waited35=0
    while [ "$waited35" -lt 30 ] && [ -n "$(state35)" ]; do
      sleep 0.1
      waited35=$((waited35 + 1))
    done
    assert_eq "serve: 承認したら自分で終了して state を消す" "" "$(state35)"
    assert_eq "serve: 終了後は listener が居ない" "no-listener" "$(http35 GET "$url35" | head -1)"
  else
    fail "serve: 起動しなかったため以降の HTTP 検証をスキップした"
  fi

  # --stop で止める。動いていなくても失敗しない (べき等)。
  url35c="$(serve35 "$S35/page/review.html" --task s35 2>/dev/null | grep -m1 '^http' || true)"
  serve35 --stop --task s35 >/dev/null 2>&1
  assert_eq "serve: --stop で listener を止めて state を消す" "" "$(state35)"
  if [ -n "$url35c" ]; then
    assert_eq "serve: --stop 後は接続できない" "no-listener" "$(http35 GET "$url35c" | head -1)"
  fi
  if serve35 --stop --task s35 >/dev/null 2>&1; then
    pass "serve: --stop はべき等 (動いていなくても成功)"
  else
    fail "serve: --stop はべき等 (動いていなくても成功)"
  fi

  # wt rm も listener を止める (worktree を消して listener だけ残る事故を防ぐ)。
  wt35 new r35 --no-claude >/dev/null 2>&1
  serve35 "$S35/page/review.html" --task r35 >/dev/null 2>&1
  wt35 rm r35 >/dev/null 2>&1
  assert_eq "rm: レビューサーバが残っていれば止める" "" "$(state35)"

  # herdr が使えなければ配信しない (呼び出し側が file:// に落ちるための契約)。
  out35="$(wt35 serve "$S35/page/review.html" --task s35 2>&1)"
  rc35=$?
  if [ "$rc35" -ne 0 ] && printf '%s' "$out35" | grep -q 'herdr'; then
    pass "serve: herdr が使えなければ起動せず失敗する"
  else
    fail "serve: herdr が使えなければ起動せず失敗する (rc=$rc35 out=$out35)"
  fi

  # 引数の検査。
  out35="$(serve35 "$S35/page/nope.html" --task s35 2>&1)"
  rc35=$?
  if [ "$rc35" -ne 0 ] && printf '%s' "$out35" | grep -q 'ファイルが無い'; then
    pass "serve: 存在しないパスを弾く"
  else
    fail "serve: 存在しないパスを弾く (rc=$rc35 out=$out35)"
  fi
  out35="$(serve35 "$S35/page/review.html" 2>&1)"
  rc35=$?
  if [ "$rc35" -ne 0 ] && printf '%s' "$out35" | grep -q 'task'; then
    pass "serve: worktree 外で task 省略は中断する"
  else
    fail "serve: worktree 外で task 省略は中断する (rc=$rc35 out=$out35)"
  fi

  # --ttl の秒数で自分を畳む (承認されず放置された listener を残さない)。
  st35="$S35/ttl.state"
  env HOME="$H35" python3 "$PY35" --html "$S35/page/review.html" --task ttl \
    --state "$st35" --ttl 1 >/dev/null 2>&1 &
  ttlpid35=$!
  waited35=0
  while [ "$waited35" -lt 50 ] && [ ! -f "$st35" ]; do
    sleep 0.1
    waited35=$((waited35 + 1))
  done
  assert_file "$st35" "serve: state ファイルを書く"
  assert_eq "serve: state に url を書く" "1" \
    "$(grep -c '^url=http://localhost:' "$st35" 2>/dev/null)"
  assert_eq "serve: state に pid を書く" "$ttlpid35" \
    "$(sed -n 's/^pid=//p' "$st35" 2>/dev/null)"
  waited35=0
  while [ "$waited35" -lt 80 ] && kill -0 "$ttlpid35" 2>/dev/null; do
    sleep 0.1
    waited35=$((waited35 + 1))
  done
  if kill -0 "$ttlpid35" 2>/dev/null; then
    kill "$ttlpid35" 2>/dev/null
    fail "serve: --ttl の秒数で自分を畳む"
  else
    pass "serve: --ttl の秒数で自分を畳む"
  fi
  wait "$ttlpid35" 2>/dev/null
  if [ -f "$st35" ]; then
    fail "serve: 終了時に state を消す"
  else
    pass "serve: 終了時に state を消す"
  fi

  if python3 -m py_compile "$PY35" >/dev/null 2>&1; then
    pass "serve: wt-review-serve.py が構文エラー無くコンパイルできる"
  else
    fail "serve: wt-review-serve.py が構文エラー無くコンパイルできる"
  fi
  rm -rf "$REPO_ROOT/__pycache__"
else
  pass "serve: python3 が無いためスキップ"
fi

if [ "$FAILED" -eq 0 ]; then
  printf '\nall tests passed\n'
else
  printf '\nsome tests FAILED\n'
fi
exit "$FAILED"
