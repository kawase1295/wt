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

if [ "$FAILED" -eq 0 ]; then
  printf '\nall tests passed\n'
else
  printf '\nsome tests FAILED\n'
fi
exit "$FAILED"
