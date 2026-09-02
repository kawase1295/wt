#!/usr/bin/env bash
# main-checkout-guard hook のテスト。依存は git / coreutils / jq。
#
#   tests/hook_test.sh
#
# hook は PreToolUse の JSON を stdin で受け、本体 checkout でのブランチ切替
# (git checkout / git switch / gh pr checkout) だけを ask に落とす。判定が cwd の
# git 状態に依存するため、temp repo を作って検証する。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/hooks/main-checkout-guard.sh"

FAILED=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  FAILED=1
}

if ! command -v jq >/dev/null 2>&1; then
  printf 'ok   - hook: jq が無いため検証をスキップ\n'
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

new_repo() { # dir
  git init -q -b main "$1"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name tester
  git -C "$1" commit -q --allow-empty -m init
}

run_hook() { # cwd command
  jq -n --arg cwd "$1" --arg cmd "$2" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' |
    "$HOOK" 2>/dev/null
}

is_ask() { printf '%s' "$1" | grep -q '"permissionDecision":"ask"'; }

assert_ask() { # desc cwd command
  local out
  out="$(run_hook "$2" "$3")"
  if is_ask "$out"; then pass "$1"; else fail "$1 (out=$out)"; fi
}

assert_pass() { # desc cwd command
  local out
  out="$(run_hook "$2" "$3")"
  if [ -z "$out" ]; then pass "$1"; else fail "$1 (out=$out)"; fi
}

# --- 検査対象の repo たち ---
R="$TMP/repo"
new_repo "$R"
git -C "$R" branch feature-x
git -C "$R" branch dev
git -C "$R" branch worktree-42-something
: >"$R/tracked.txt"
git -C "$R" add tracked.txt
git -C "$R" commit -q -m "add file"

W="$TMP/repo-wt"
git -C "$R" worktree add -q "$W" -b worktree-guard-test

# --- 本体 checkout: ブランチ切替は ask ---
assert_ask "hook: checkout -b は ask" "$R" "git checkout -b feature-new"
assert_ask "hook: checkout -B は ask" "$R" "git checkout -B feature-new"
assert_ask "hook: switch -c は ask" "$R" "git switch -c feature-new"
assert_ask "hook: switch -C は ask" "$R" "git switch -C feature-new"
assert_ask "hook: 既存ブランチへの checkout は ask" "$R" "git checkout feature-x"
assert_ask "hook: 既存ブランチへの switch は ask" "$R" "git switch feature-x"
assert_ask "hook: worktree-* への切替も ask (wt open を使う)" "$R" "git checkout worktree-42-something"
assert_ask "hook: クォート付きのブランチ名も見る" "$R" 'git checkout "feature-x"'
assert_ask "hook: 複合コマンドの中でも検出する" "$R" "cd /tmp && git checkout -b feature-new"
assert_ask "hook: git -C 付きでも検出する" "$R" "git -C $R checkout -b feature-new"
assert_ask "hook: 絶対パスの git でも検出する" "$R" "/usr/bin/git checkout -b feature-new"

# ローカルに無くても remote にあれば git は追跡ブランチを作って切り替える (DWIM)。
git -C "$R" update-ref refs/remotes/origin/remote-only "$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/dev "$(git -C "$R" rev-parse HEAD)"
assert_ask "hook: remote にだけあるブランチへの checkout も ask" "$R" "git checkout remote-only"
assert_ask "hook: --track は ask" "$R" "git checkout --track origin/remote-only"
assert_ask "hook: -t は ask" "$R" "git checkout -t origin/remote-only"
assert_ask "hook: checkout --orphan は ask" "$R" "git checkout --orphan gh-pages"
assert_ask "hook: switch --orphan は ask" "$R" "git switch --orphan fresh"
assert_ask "hook: 括弧で囲まれたブランチ切替も検出する" "$R" "(git checkout -b feature-new)"

# --- 本体 checkout: gh pr checkout もブランチを切り替えるので ask ---
assert_ask "hook: gh pr checkout <番号> は ask" "$R" "gh pr checkout 5"
assert_ask "hook: gh pr checkout <URL> は ask" "$R" "gh pr checkout https://github.com/o/r/pull/5"
assert_ask "hook: gh pr checkout <ブランチ名> は ask" "$R" "gh pr checkout feature-x"
assert_ask "hook: gh pr checkout -b <名前> は ask" "$R" "gh pr checkout 5 -b local-name"
assert_ask "hook: gh pr checkout --detach は ask" "$R" "gh pr checkout --detach 5"
assert_ask "hook: gh pr checkout -R <repo> は ask" "$R" "gh pr checkout -R owner/repo 5"
assert_ask "hook: gh pr checkout の引数なしも ask" "$R" "gh pr checkout"
assert_ask "hook: 絶対パスの gh でも検出する" "$R" "/usr/bin/gh pr checkout 5"
assert_ask "hook: 複合コマンドの中の gh pr checkout も検出する" "$R" "gh pr view 5 && gh pr checkout 5"

# ask の中身は JSON として妥当で、PR の指定を名指しする。
out_pr="$(run_hook "$R" "gh pr checkout 5")"
if printf '%s' "$out_pr" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("PR「5」")' >/dev/null 2>&1; then
  pass "hook: gh の ask は妥当な JSON で PR 指定を含む"
else
  fail "hook: gh の ask は妥当な JSON で PR 指定を含む (out=$out_pr)"
fi

# --- 本体 checkout: 素通しする経路 ---
assert_pass "hook: default branch への切替は素通し" "$R" "git checkout main"
assert_pass "hook: dev への切替は素通し" "$R" "git checkout dev"
assert_pass "hook: -- 付きのファイル復元は素通し" "$R" "git checkout -- tracked.txt"
assert_pass "hook: ブランチでないパスの checkout は素通し" "$R" "git checkout tracked.txt"
assert_pass "hook: remote-tracking ref の直接 checkout (detached) は素通し" "$R" "git checkout origin/remote-only"
assert_pass "hook: 無関係な git コマンドは素通し" "$R" "git status"
assert_pass "hook: worktree add は素通し" "$R" "git worktree add ../x -b y"
assert_pass "hook: switch の引数なしは素通し" "$R" "git switch"
assert_pass "hook: checkout / switch を含まないコマンドは素通し" "$R" "ls -la"
assert_pass "hook: --track で remote 付きの許可ブランチは素通し" "$R" "git checkout -t origin/dev"
assert_pass "hook: gh pr view は素通し" "$R" "gh pr view 5"
assert_pass "hook: checkout を含む gh の別コマンドは素通し" "$R" "gh pr list --search checkout"
assert_pass "hook: gh の checkout でないサブコマンドは素通し" "$R" "gh pr diff 5 --name-only"
assert_pass "hook: gh 以外のコマンドの引数に並んでいても素通し" "$R" "echo gh pr checkout 5"

# --- 直前ブランチ (-) は解決してから判定する ---
git -C "$R" checkout -q feature-x # 直前は main
assert_pass "hook: - が許可ブランチに戻るなら素通し" "$R" "git checkout -"
git -C "$R" checkout -q main # 直前は feature-x
assert_ask "hook: - が許可外ブランチに戻るなら ask" "$R" "git checkout -"

# --- worktree 内は素通し ---
assert_pass "hook: worktree 内の checkout -b は素通し" "$W" "git checkout -b another"
assert_pass "hook: worktree 内の既存ブランチ切替も素通し" "$W" "git checkout feature-x"
assert_pass "hook: worktree 内の gh pr checkout は素通し" "$W" "gh pr checkout 5"

# --- repo 外 / 壊れた入力 ---
assert_pass "hook: git repo でなければ素通し" "$TMP" "git checkout -b x"
assert_pass "hook: cwd が存在しなければ素通し" "$TMP/no-such-dir" "git checkout -b x"
out_broken="$(printf 'not json' | "$HOOK" 2>/dev/null)"
if [ -z "$out_broken" ]; then
  pass "hook: JSON でない入力は素通し"
else
  fail "hook: JSON でない入力は素通し (out=$out_broken)"
fi

# --- 逃げ道 ---
out_off="$(WT_GUARD_DISABLE=1 run_hook "$R" "git checkout -b feature-new")"
if [ -z "$out_off" ]; then
  pass "hook: WT_GUARD_DISABLE=1 で無効化できる"
else
  fail "hook: WT_GUARD_DISABLE=1 で無効化できる (out=$out_off)"
fi

out_off_pr="$(WT_GUARD_DISABLE=1 run_hook "$R" "gh pr checkout 5")"
if [ -z "$out_off_pr" ]; then
  pass "hook: WT_GUARD_DISABLE=1 は gh pr checkout にも効く"
else
  fail "hook: WT_GUARD_DISABLE=1 は gh pr checkout にも効く (out=$out_off_pr)"
fi

out_allow="$(WT_GUARD_ALLOW_BRANCHES=feature-x run_hook "$R" "git checkout feature-x")"
if [ -z "$out_allow" ]; then
  pass "hook: WT_GUARD_ALLOW_BRANCHES で許可を差し替えられる"
else
  fail "hook: WT_GUARD_ALLOW_BRANCHES で許可を差し替えられる (out=$out_allow)"
fi

out_allow2="$(WT_GUARD_ALLOW_BRANCHES=feature-x run_hook "$R" "git checkout dev")"
if is_ask "$out_allow2"; then
  pass "hook: 差し替えると既定の許可名は外れる"
else
  fail "hook: 差し替えると既定の許可名は外れる (out=$out_allow2)"
fi

# --- default branch は origin/HEAD から引く ---
R2="$TMP/repo2"
new_repo "$R2"
git -C "$R2" branch release
git -C "$R2" update-ref refs/remotes/origin/release "$(git -C "$R2" rev-parse HEAD)"
git -C "$R2" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/release
assert_pass "hook: origin/HEAD の指す default branch は素通し" "$R2" "git checkout release"

# --- plugin への配線 ---
HJ="$ROOT/hooks/hooks.json"
if [ -f "$HJ" ] && jq -e . "$HJ" >/dev/null 2>&1; then
  pass "hook: hooks.json は妥当な JSON"
else
  fail "hook: hooks.json は妥当な JSON"
fi
if [ -f "$HJ" ]; then
  matcher="$(jq -r '.hooks.PreToolUse[0].matcher // ""' "$HJ")"
  cmdline="$(jq -r '.hooks.PreToolUse[0].hooks[0].command // ""' "$HJ")"
  if [ "$matcher" = "Bash" ]; then
    pass "hook: PreToolUse の matcher は Bash"
  else
    fail "hook: PreToolUse の matcher は Bash (matcher=$matcher)"
  fi
  case "$cmdline" in
    *CLAUDE_PLUGIN_ROOT*main-checkout-guard.sh*)
      pass "hook: command は plugin root 相対でスクリプトを指す" ;;
    *)
      fail "hook: command は plugin root 相対でスクリプトを指す (command=$cmdline)" ;;
  esac
fi
if [ -x "$HOOK" ]; then
  pass "hook: スクリプトは実行可能"
else
  fail "hook: スクリプトは実行可能"
fi

PLG="$ROOT/.claude-plugin/plugin.json"
declared="$(jq -r '.hooks // ""' "$PLG" 2>/dev/null)"
if [ "$declared" = "./hooks/hooks.json" ]; then
  pass "hook: plugin.json が hooks.json を宣言している"
else
  fail "hook: plugin.json が hooks.json を宣言している (hooks=$declared)"
fi

if [ "$FAILED" -eq 0 ]; then
  printf '\nall hook tests passed\n'
else
  printf '\nsome hook tests FAILED\n'
fi
exit "$FAILED"
