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

# --- test 21: fake herdr で claude の起動 argv を検証する ---
# 既定で --model opus --permission-mode auto が入り、--prompt は argv 1 要素のまま渡る。
# WT_CLAUDE_ARGS でフラグを差し替えられ、空文字ならフラグ無しになる。
if [ -x /usr/bin/jq ]; then
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/herdr" <<'STUB'
#!/usr/bin/env bash
# テスト用 herdr スタブ。worktree create は実際に git worktree を作り、
# agent start は -- 以降の argv を 1 行 1 要素で HERDR_ARGV_LOG に記録する。
set -euo pipefail
cmd="${1:-} ${2:-}"
case "$cmd" in
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
    printf '{"result":{"workspace":{"workspace_id":"ws-stub"},"worktree":{"path":"%s"}}}\n' "$path"
    ;;
  "agent start")
    shift 2
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
    shift
    : >"$HERDR_ARGV_LOG"
    for a in "$@"; do printf '%s\n' "$a" >>"$HERDR_ARGV_LOG"; done
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TMP/bin/herdr"
  R21="$TMP/repo21"
  new_repo "$R21"
  LOG21="$TMP/agent-argv.log"
  (cd "$R21" && env -u WT_HOME -u WT_CLAUDE_ARGS HOME="$TMP/home" HERDR_ARGV_LOG="$LOG21" \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new p21 --prompt "hello world") >/dev/null 2>&1
  argc="$(wc -l <"$LOG21" 2>/dev/null | tr -d ' ')"
  assert_eq "stub: agent start の argv が claude + 既定フラグ + prompt の 6 要素" "6" "$argc"
  assert_eq "stub: argv[0] が claude" "claude" "$(sed -n 1p "$LOG21" 2>/dev/null)"
  assert_eq "stub: 既定フラグが --model opus --permission-mode auto" \
    "--model opus --permission-mode auto" "$(sed -n 2,5p "$LOG21" 2>/dev/null | paste -sd' ' -)"
  assert_eq "stub: 末尾 argv が prompt 全体 (分割されない)" "hello world" "$(sed -n 6p "$LOG21" 2>/dev/null)"

  # WT_CLAUDE_ARGS でフラグを差し替える
  LOG21B="$TMP/agent-argv-b.log"
  (cd "$R21" && env -u WT_HOME HOME="$TMP/home" HERDR_ARGV_LOG="$LOG21B" WT_CLAUDE_ARGS="--model sonnet" \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new p21b --prompt "hi") >/dev/null 2>&1
  assert_eq "stub: WT_CLAUDE_ARGS でフラグを差し替えられる" \
    "claude --model sonnet hi" "$(paste -sd' ' - <"$LOG21B" 2>/dev/null)"

  # WT_CLAUDE_ARGS="" (空文字) でフラグ無し
  LOG21C="$TMP/agent-argv-c.log"
  (cd "$R21" && env -u WT_HOME HOME="$TMP/home" HERDR_ARGV_LOG="$LOG21C" WT_CLAUDE_ARGS="" \
    PATH="$TMP/bin:$SAFE_PATH" "$WT" new p21c --prompt "hi") >/dev/null 2>&1
  assert_eq "stub: WT_CLAUDE_ARGS 空文字でフラグ無し" \
    "claude hi" "$(paste -sd' ' - <"$LOG21C" 2>/dev/null)"
else
  pass "stub: jq が無いためスキップ"
fi

# --- test 22: install.sh は skills を ~/.claude/skills に配置する ---
INSTALL="$(dirname "$WT")/install.sh"
H22="$TMP/home22"
mkdir -p "$H22"
env HOME="$H22" PREFIX="$TMP/bin22" PATH="$SAFE_PATH" bash "$INSTALL" >/dev/null 2>&1
ok22=1
for s in worktree-parallel wt wt-detail wt-review wt-merge wt-clean local-artifact; do
  [ -f "$H22/.claude/skills/$s/SKILL.md" ] || ok22=0
done
if [ "$ok22" -eq 1 ]; then
  pass "install: skills 7 個を ~/.claude/skills に配置する"
else
  fail "install: skills 7 個を ~/.claude/skills に配置する"
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

if [ "$FAILED" -eq 0 ]; then
  printf '\nall tests passed\n'
else
  printf '\nsome tests FAILED\n'
fi
exit "$FAILED"
