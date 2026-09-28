#!/usr/bin/env bash
# wt loop のテスト。依存は git / jq / coreutils のみ。
#
#   tests/loop_test.sh
#
# claude と gh は PATH に置いた stub で差し替える。git は本物で、bare の origin と
# 本体 checkout を temp に作り、push / merge / pull / worktree の実体を検証する。
# claude stub は呼び出し k 回目に $CLAUDE_STUB_DIR/step-<k>.sh があればそれを cwd
# (worktree) で実行して stdout を envelope として返す (無ければ既定の成功応答)。
# gh stub は issue / PR / label の状態を $GH_STUB_DIR 配下の JSON で持ち、
# pr merge は origin の default branch に実際にマージする。
set -uo pipefail

# wt loop の sandbox (push 禁止の GIT_CONFIG_* / 無認証の GH_CONFIG_DIR) の中で
# scripts/check として走らされても、外の環境に左右されないよう最初に隔離する。
# テストが必要とする環境は各ヘルパーが明示的に組み立てる。
unset GIT_CONFIG_COUNT GH_CONFIG_DIR GIT_TERMINAL_PROMPT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WT="$REPO_ROOT/wt"
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
assert_contains() { # desc haystack needle
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing: $3)" ;; esac
}
assert_not_contains() { # desc haystack needle
  case "$2" in *"$3"*) fail "$1 (unexpected: $3)" ;; *) pass "$1" ;; esac
}
assert_dir() { if [ -d "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi; }
assert_no_dir() { if [ ! -d "$1" ]; then pass "$2"; else fail "$2 (unexpected: $1)"; fi; }
has_branch() { git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null 2>&1; }

if ! command -v jq >/dev/null 2>&1; then
  echo "skip - jq が無いため wt loop のテストをスキップ"
  exit 0
fi

TMP="$(mktemp -d)"
# KEEP_TMP=1 で temp を残す (失敗時に state / stub のログを見るため)
trap '[ -n "${KEEP_TMP:-}" ] && echo "tmp: $TMP" || rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/bin"

# --- stub: claude -------------------------------------------------------------
cat >"$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
# claude -p の stub。stdin のプロンプトと argv と cwd を記録し、k 回目の呼び出しに
# step-<k>.sh があればそれを実行して stdout を envelope として返す。
set -uo pipefail
d="$CLAUDE_STUB_DIR"
k=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$k" >"$d/count"
cat >"$d/prompt-$k.txt"
printf '%s\n' "$@" >"$d/argv-$k.txt"
pwd -P >"$d/cwd-$k.txt"
# worker / reviewer に渡る環境 (push 禁止の GIT_CONFIG_* と無認証の gh) を記録する
{ printenv | grep -E '^(GIT_CONFIG|GH_CONFIG_DIR|GH_TOKEN|GITHUB_TOKEN|GIT_TERMINAL_PROMPT)' || true; } >"$d/env-$k.txt"
if [ -x "$d/step-$k.sh" ]; then
  exec "$d/step-$k.sh"
fi
case " $* " in
  *" --json-schema "*)
    printf '{"type":"result","subtype":"success","is_error":false,"result":"{\\"verdict\\":\\"PASS\\",\\"summary\\":\\"ok\\",\\"findings\\":[]}","structured_output":{"verdict":"PASS","summary":"問題なし","findings":[{"severity":"minor","file":"a.txt","summary":"些細"}]}}\n'
    ;;
  *)
    printf '{"type":"result","subtype":"success","is_error":false,"result":"## 変更\\n既定の応答"}\n'
    ;;
esac
STUB
chmod +x "$TMP/bin/claude"

# --- stub: gh -----------------------------------------------------------------
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh の stub。issues.json / labels / prs.json を状態として持つ。
set -uo pipefail
d="$GH_STUB_DIR"
printf '%s\n' "$*" >>"$d/gh.log"
issues="$d/issues.json"
case "${1:-} ${2:-}" in
  "repo view")
    case "$*" in
      *defaultBranchRef*) echo dev ;;
      *) echo '{"nameWithOwner":"t/repo"}' ;;
    esac
    ;;
  "issue list")
    # 本物と同じく新しい順 (番号の降順) で返す
    label=""
    while [ $# -gt 0 ]; do [ "$1" = "--label" ] && label="$2"; shift; done
    jq -r --arg l "$label" '[.[] | select(.state == "OPEN") | select([.labels[]?.name] | index($l) != null) | .number] | sort | reverse | .[]' "$issues"
    ;;
  "issue view")
    jq -e --argjson n "$3" '.[] | select(.number == $n)' "$issues" >/dev/null || exit 1
    case "$*" in
      *"--json state -q .state"*) jq -r --argjson n "$3" '.[] | select(.number == $n) | .state' "$issues" ;;
      *) jq -c --argjson n "$3" '.[] | select(.number == $n)' "$issues" ;;
    esac
    ;;
  "issue close")
    jq --argjson n "$3" 'map(if .number == $n then .state = "CLOSED" else . end)' "$issues" >"$issues.tmp" && mv "$issues.tmp" "$issues"
    ;;
  "issue comment")
    n="$3"
    k=$(( $(ls "$d"/comment-"$n"-* 2>/dev/null | wc -l) + 1 ))
    while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$d/comment-$n-$k.md"; shift; done
    ;;
  "issue edit")
    n="$3"
    while [ $# -gt 0 ]; do
      if [ "$1" = "--add-label" ]; then
        jq --argjson n "$n" --arg l "$2" 'map(if .number == $n then .labels += [{"name": $l}] else . end)' "$issues" >"$issues.tmp" && mv "$issues.tmp" "$issues"
      fi
      shift
    done
    ;;
  "label list") cat "$d/labels" 2>/dev/null ;;
  "label create") printf '%s\n' "$3" >>"$d/labels" ;;
  "pr list")
    head=""
    while [ $# -gt 0 ]; do [ "$1" = "--head" ] && head="$2"; shift; done
    jq -r --arg b "$head" 'to_entries[] | select(.value == $b) | .key' "$d/prs.json" 2>/dev/null | head -1
    ;;
  "pr create")
    head="" base="" body=""
    while [ $# -gt 0 ]; do
      case "$1" in --head) head="$2" ;; --base) base="$2" ;; --body-file) body="$2" ;; esac
      shift
    done
    k=$(( $(jq 'length' "$d/prs.json" 2>/dev/null || echo 0) + 1 ))
    url="https://example.test/pr/$k"
    cp "$body" "$d/pr-$k-body.md"
    printf '%s\n' "$base" >"$d/pr-$k-base"
    jq --arg u "$url" --arg b "$head" '. + {($u): $b}' "$d/prs.json" >"$d/prs.json.tmp" 2>/dev/null || printf '{"%s":"%s"}' "$url" "$head" >"$d/prs.json.tmp"
    mv "$d/prs.json.tmp" "$d/prs.json"
    echo "$url"
    ;;
  "pr checks")
    if [ -e "$d/checks-none-once" ] || [ -e "$d/checks-none" ]; then
      rm -f "$d/checks-none-once"
      echo "no checks reported on the 'x' branch" >&2
      exit 1
    fi
    if [ -e "$d/checks-fail-once" ]; then
      rm -f "$d/checks-fail-once"
      printf 'X\tcheck\t1m\thttps://example.test/run/1\nfail: check\n'
      exit 1
    fi
    printf '✓\tcheck\t1m\thttps://example.test/run/1\n'
    ;;
  "pr merge")
    [ -e "$d/merge-fail" ] && { echo "Pull request is not mergeable" >&2; exit 1; }
    url="$3"
    branch="$(jq -r --arg u "$url" '.[$u]' "$d/prs.json")"
    clone="$d/merge-clone"
    rm -rf "$clone"
    git clone -q -b dev "$GH_STUB_ORIGIN" "$clone"
    git -C "$clone" -c user.email=gh@example.com -c user.name=gh merge -q --no-ff -m "Merge pull request $url" "origin/$branch" || exit 1
    git -C "$clone" push -q origin dev
    # GitHub と同じく、PR 本文の Fixes #N で issue を閉じる (GH_STUB_NO_AUTOCLOSE=1 で閉じない)
    if [ "${GH_STUB_NO_AUTOCLOSE:-0}" != "1" ]; then
      k="${url##*/}"
      fixes="$(grep -oE 'Fixes #[0-9]+' "$d/pr-$k-body.md" | grep -oE '[0-9]+' | head -1)"
      if [ -n "$fixes" ]; then
        jq --argjson n "$fixes" 'map(if .number == $n then .state = "CLOSED" else . end)' "$issues" >"$issues.tmp" && mv "$issues.tmp" "$issues"
      fi
    fi
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# --- fixture: origin + 本体 checkout --------------------------------------------
# scripts/check は worktree に bad というファイルがあれば失敗する (check 失敗の再現用)。
make_fixture() { # name → $REPO $ORIGIN を設定
  local name="$1"
  ORIGIN="$TMP/$name-origin.git"
  REPO="$TMP/$name"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/dev
  git init -q -b dev "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  mkdir -p "$REPO/scripts"
  cat >"$REPO/scripts/check" <<'CHK'
#!/usr/bin/env bash
pwd -P >>"${CHECK_LOG:-/dev/null}"
[ ! -e bad ]
CHK
  chmod +x "$REPO/scripts/check"
  printf 'base\n' >"$REPO/shared.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm init
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" push -q -u origin dev
  printf '.claude/worktrees/\n' >>"$REPO/.git/info/exclude"

  GH_STUB_DIR="$TMP/$name-gh"
  CLAUDE_STUB_DIR="$TMP/$name-claude"
  STATE_ROOT="$TMP/$name-state"
  mkdir -p "$GH_STUB_DIR" "$CLAUDE_STUB_DIR" "$STATE_ROOT"
  printf '[]\n' >"$GH_STUB_DIR/issues.json"
  printf '{}\n' >"$GH_STUB_DIR/prs.json"
  export GH_STUB_DIR CLAUDE_STUB_DIR
}

add_issue() { # number title state labels(csv) body
  local labels
  labels="$(printf '%s' "$4" | tr ',' '\n' | sed '/^$/d' | jq -R '{name: .}' | jq -s .)"
  jq --argjson n "$1" --arg t "$2" --arg s "$3" --argjson l "$labels" --arg b "$5" \
    '. + [{number: $n, title: $t, state: $s, labels: $l, body: $b, url: ("https://example.test/issues/" + ($n|tostring))}]' \
    "$GH_STUB_DIR/issues.json" >"$GH_STUB_DIR/issues.json.tmp"
  mv "$GH_STUB_DIR/issues.json.tmp" "$GH_STUB_DIR/issues.json"
}

# worker の step: ファイルを書いてコミットし、報告を返す
worker_step() { # k file content [report]
  cat >"$CLAUDE_STUB_DIR/step-$1.sh" <<EOF
#!/usr/bin/env bash
set -e
printf '%s\n' '$3' >'$2'
git add -A
git -c user.email=w@example.com -c user.name=worker commit -qm 'implement'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"${4:-## 変更\\n$2 を追加した}"}'
EOF
  chmod +x "$CLAUDE_STUB_DIR/step-$1.sh"
}

reviewer_step() { # k verdict summary findings_json
  cat >"$CLAUDE_STUB_DIR/step-$1.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"{}","structured_output":{"verdict":"$2","summary":"$3","findings":$4}}'
EOF
  chmod +x "$CLAUDE_STUB_DIR/step-$1.sh"
}

# wt loop を stub 付きで実行する (stdout + stderr をまとめて返す)
loop() { # args...
  (cd "$REPO" && env -u WT_HOME HOME="$TMP/home" PATH="$TMP/bin:$SAFE_PATH" \
    WT_LOOP_STATE="$STATE_ROOT" WT_LOOP_CHECKS_GRACE=0 WT_LOOP_INFRA_SECS="${INFRA_SECS:-0}" \
    GH_STUB_ORIGIN="$ORIGIN" CHECK_LOG="$TMP/check.log" \
    "$WT" loop "$@" 2>&1)
}
state_dir() { # number
  find "$STATE_ROOT" -mindepth 2 -maxdepth 2 -type d -name "$1" 2>/dev/null | head -1
}
claude_calls() { cat "$CLAUDE_STUB_DIR/count" 2>/dev/null || echo 0; }

# --- test 1: 対象の選択と --dry-run ---------------------------------------------
make_fixture t1
add_issue 1 "Add greeting" OPEN "wt-loop" "## 受け入れ条件
- [ ] hello を出す"
add_issue 2 "Needs human" OPEN "wt-loop,needs-human" "x"
add_issue 3 "No label" OPEN "" "x"
add_issue 4 "Parent" OPEN "wt-loop" "## 背景
親

## 子タスク

- [ ] #5 Child A
- [ ] #6 Child B（#5 のあと）
- [ ] #7 Child C (#3 の後)
- [x] #9 Done child

## 受け入れ条件
- [ ] #99 これは子ではない"
add_issue 5 "Child A" OPEN "" "x"
add_issue 6 "Child B" OPEN "" "x"
add_issue 7 "Child C" OPEN "" "x"
add_issue 9 "Done child" CLOSED "" "x"
add_issue 8 "In progress" OPEN "wt-loop" "x"
git -C "$REPO" branch worktree-8-in-progress
add_issue 11 "Closed one" CLOSED "wt-loop" "x"
out="$(loop --dry-run)"
assert_contains "dry-run: ラベル付き open issue を対象にする" "$out" "#1 Add greeting"
assert_not_contains "dry-run: needs-human は飛ばす" "$out" "#2 Needs human"
assert_not_contains "dry-run: ラベル無しは対象外" "$out" "#3 No label"
assert_contains "dry-run: 親 issue は子に展開する" "$out" "#4 は親 issue"
assert_contains "dry-run: 依存の無い子を対象にする" "$out" "#5 Child A"
assert_contains "dry-run: 依存が OPEN の子は待つ" "$out" "skip #6: 依存 #5 が未完了"
assert_contains "dry-run: (#N の後) 表記も依存として読む" "$out" "skip #7: 依存 #3 が未完了"
assert_contains "dry-run: CLOSED の子は飛ばす" "$out" "skip #9: CLOSED"
assert_not_contains "dry-run: 子タスク節の外のチェックリストは子ではない" "$out" "#99"
assert_contains "dry-run: ブランチが既にある issue は進行中として飛ばす" "$out" "skip #8: 進行中 (worktree-8-in-progress)"
assert_not_contains "dry-run: CLOSED の issue は一覧に出ない" "$out" "#11"
assert_contains "dry-run: ここで終わる" "$out" "--dry-run のためここで終わる"
assert_eq "dry-run: claude を呼ばない" "0" "$(claude_calls)"
assert_no_dir "$REPO/.claude/worktrees/1-add-greeting" "dry-run: worktree を作らない"
out="$(loop 3 11 --dry-run)"
assert_contains "dry-run: 番号指定はラベルを問わず対象にする" "$out" "#3 No label"
assert_contains "dry-run: 番号指定でも CLOSED は飛ばす" "$out" "skip #11: CLOSED"
assert_contains "dry-run: 無いラベルは作る" "$(cat "$GH_STUB_DIR/labels")" "wt-loop"
assert_contains "dry-run: needs-human ラベルも作る" "$(cat "$GH_STUB_DIR/labels")" "needs-human"

# --- test 2: 正常系 — worker → check → reviewer PASS → PR → CI → merge → 片付け ---
make_fixture t2
add_issue 10 "Add greeting" OPEN "wt-loop" "## 受け入れ条件
- [ ] hello を出す"
worker_step 1 hello.txt hello '## 変更\\nhello.txt を追加した\\n\\n前提: なし'
reviewer_step 2 PASS "受け入れ条件を満たす" '[{"severity":"minor","file":"hello.txt","summary":"改行"}]'
out="$(loop)"
sd="$(state_dir 10)"
assert_eq "loop: status が merged" "merged" "$(cat "$sd/status" 2>/dev/null)"
assert_eq "loop: task 名は <N>-<slug>" "10-add-greeting" "$(cat "$sd/task" 2>/dev/null)"
assert_eq "loop: worker と reviewer で claude を 2 回呼ぶ" "2" "$(claude_calls)"
assert_contains "loop: worker は worktree で動く" "$(cat "$CLAUDE_STUB_DIR/cwd-1.txt")" "/.claude/worktrees/10-add-greeting"
assert_contains "loop: worker の argv に acceptEdits" "$(cat "$CLAUDE_STUB_DIR/argv-1.txt")" "acceptEdits"
assert_contains "loop: worker の argv に --session-id" "$(cat "$CLAUDE_STUB_DIR/argv-1.txt")" "--session-id"
assert_contains "loop: worker の allowlist に git" "$(cat "$CLAUDE_STUB_DIR/argv-1.txt")" "Bash(git *)"
assert_contains "loop: worker のプロンプトに issue 本文" "$(cat "$CLAUDE_STUB_DIR/prompt-1.txt")" "hello を出す"
assert_contains "loop: worker のプロンプトに push 禁止" "$(cat "$CLAUDE_STUB_DIR/prompt-1.txt")" "git push / PR 作成 / merge / ブランチ切替はしない"
assert_contains "loop: reviewer の argv に --json-schema" "$(cat "$CLAUDE_STUB_DIR/argv-2.txt")" "--json-schema"
assert_contains "loop: reviewer は default モード + 読み取り系だけ" "$(cat "$CLAUDE_STUB_DIR/argv-2.txt")" "Read,Glob,Grep,Bash(git diff *)"
assert_contains "loop: reviewer のプロンプトに diff のパス" "$(cat "$CLAUDE_STUB_DIR/prompt-2.txt")" "round-1.diff"
assert_contains "loop: diff を保存する" "$(cat "$sd/round-1.diff")" "+hello"
assert_contains "loop: scripts/check を worktree で実行する" "$(cat "$TMP/check.log")" "/.claude/worktrees/10-add-greeting"
ghlog="$(cat "$GH_STUB_DIR/gh.log")"
assert_contains "loop: PR は default branch を base に作る" "$ghlog" "pr create --base dev --head worktree-10-add-greeting --title Add greeting"
assert_contains "loop: PR 本文に Fixes #N" "$(cat "$GH_STUB_DIR/pr-1-body.md")" "Fixes #10"
assert_contains "loop: PR 本文に worker の報告" "$(cat "$GH_STUB_DIR/pr-1-body.md")" "hello.txt を追加した"
assert_contains "loop: PR 本文に AI レビュー要約" "$(cat "$GH_STUB_DIR/pr-1-body.md")" "受け入れ条件を満たす"
assert_contains "loop: レビュー記録を issue にコメントする" "$(cat "$GH_STUB_DIR/comment-10-1.md")" "判定: PASS"
assert_contains "loop: CI を待つ" "$ghlog" "pr checks https://example.test/pr/1 --watch"
assert_contains "loop: gh pr merge --merge" "$ghlog" "pr merge https://example.test/pr/1 --merge"
assert_eq "loop: origin の dev に成果が入る" "hello" "$(git -C "$ORIGIN" show dev:hello.txt 2>/dev/null)"
assert_eq "loop: 本体 checkout を ff で追随させる" "hello" "$(cat "$REPO/hello.txt" 2>/dev/null)"
if git -C "$ORIGIN" rev-parse --verify -q refs/heads/worktree-10-add-greeting >/dev/null; then
  fail "loop: remote ブランチを削除する"
else
  pass "loop: remote ブランチを削除する"
fi
assert_no_dir "$REPO/.claude/worktrees/10-add-greeting" "loop: worktree を片付ける"
if has_branch "$REPO" worktree-10-add-greeting; then fail "loop: ローカルブランチを削除する"; else pass "loop: ローカルブランチを削除する"; fi
assert_contains "loop: 終了サマリ" "$out" "処理 1 件 / マージ 1 件"

# --- test 3: check 失敗 → 同じ session に指摘を渡して次ラウンド ------------------
make_fixture t3
add_issue 20 "Fix check" OPEN "wt-loop" "x"
worker_step 1 bad x                       # bad があると scripts/check が落ちる
cat >"$CLAUDE_STUB_DIR/step-2.sh" <<'EOF'
#!/usr/bin/env bash
set -e
git rm -q bad
printf 'ok\n' >good.txt
git add -A
git -c user.email=w@example.com -c user.name=worker commit -qm fix
printf '{"type":"result","subtype":"success","is_error":false,"result":"直した"}\n'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-2.sh"
reviewer_step 3 PASS ok '[]'
out="$(loop)"
sd="$(state_dir 20)"
assert_eq "check 失敗: round 2 で通る" "2" "$(cat "$sd/round" 2>/dev/null)"
assert_eq "check 失敗: 最終的に merged" "merged" "$(cat "$sd/status" 2>/dev/null)"
assert_contains "check 失敗: round 2 は --resume で同じ session" "$(tr '\n' ' ' <"$CLAUDE_STUB_DIR/argv-2.txt")" "--resume $(cat "$sd/session-id") "
assert_contains "check 失敗: プロンプトに check のログ" "$(cat "$CLAUDE_STUB_DIR/prompt-2.txt")" "scripts/check が失敗した"
assert_contains "check 失敗: round 1 では reviewer を呼ばない" "$(cat "$CLAUDE_STUB_DIR/argv-3.txt")" "--json-schema"
assert_contains "check 失敗: ログを残す" "$(ls "$sd")" "round-1.check.log"

# --- test 4: レビュー FAIL → 指摘を渡して次ラウンド → PASS ---------------------
make_fixture t4
add_issue 30 "Review loop" OPEN "wt-loop" "x"
worker_step 1 a.txt v1
reviewer_step 2 FAIL "境界値が未検証" '[{"severity":"major","file":"a.txt","summary":"空入力で落ちる"},{"severity":"minor","file":"a.txt","summary":"命名"}]'
worker_step 3 a.txt v2
reviewer_step 4 PASS ok '[]'
out="$(loop)"
sd="$(state_dir 30)"
assert_eq "review FAIL: 4 回呼ぶ (worker, reviewer, worker, reviewer)" "4" "$(claude_calls)"
assert_contains "review FAIL: 判定をプロンプトに渡す" "$(cat "$CLAUDE_STUB_DIR/prompt-3.txt")" "AI レビューの判定: FAIL"
assert_contains "review FAIL: major の指摘を渡す" "$(cat "$CLAUDE_STUB_DIR/prompt-3.txt")" "[major] a.txt"
assert_not_contains "review FAIL: minor は渡さない" "$(cat "$CLAUDE_STUB_DIR/prompt-3.txt")" "[minor]"
assert_eq "review FAIL: 最終的に merged" "merged" "$(cat "$sd/status" 2>/dev/null)"
assert_eq "review FAIL: reviewer は毎回別セッション (--no-session-persistence)" "2" "$(grep -c -- '--no-session-persistence' "$CLAUDE_STUB_DIR/argv-2.txt" "$CLAUDE_STUB_DIR/argv-4.txt" | awk -F: '{s+=$2} END{print s}')"

# --- test 5: ラウンド上限 → needs-human に切り出し、worktree は残す ----------------
make_fixture t5
add_issue 40 "Hard one" OPEN "wt-loop" "x"
add_issue 41 "Next one" OPEN "wt-loop" "x"
worker_step 1 a.txt v1
reviewer_step 2 FAIL "だめ" '[{"severity":"blocker","file":"a.txt","summary":"壊れている"}]'
worker_step 3 b.txt v1
reviewer_step 4 PASS ok '[]'
out="$(loop --max-rounds 1)"
sd="$(state_dir 40)"
assert_eq "上限: status が needs-human" "needs-human" "$(cat "$sd/status" 2>/dev/null)"
assert_contains "上限: needs-human ラベルを付ける" "$(cat "$GH_STUB_DIR/gh.log")" "issue edit 40 --add-label needs-human"
assert_contains "上限: 経緯を issue にコメントする" "$(cat "$GH_STUB_DIR/comment-40-1.md")" "ラウンド上限 (1) に達した"
assert_contains "上限: コメントに worktree の場所" "$(cat "$GH_STUB_DIR/comment-40-1.md")" "/.claude/worktrees/40-hard-one"
assert_dir "$REPO/.claude/worktrees/40-hard-one" "上限: worktree を残す"
assert_not_contains "上限: PR は作らない" "$(cat "$GH_STUB_DIR/gh.log")" "pr create --base dev --head worktree-40"
assert_eq "上限: 次の issue に進む" "merged" "$(cat "$(state_dir 41)/status" 2>/dev/null)"
assert_contains "上限: サマリに件数" "$out" "処理 2 件 / マージ 1 件 / needs-human 1 件"

# --- test 6: worker が BLOCKED: を返したら即エスカレーション ----------------------
make_fixture t6
add_issue 50 "Needs prod" OPEN "wt-loop" "x"
cat >"$CLAUDE_STUB_DIR/step-1.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"\nBLOCKED: 本番の認証情報が要る\n詳細"}'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-1.sh"
out="$(loop)"
assert_eq "BLOCKED: status が needs-human" "needs-human" "$(cat "$(state_dir 50)/status" 2>/dev/null)"
assert_eq "BLOCKED: reviewer を呼ばずに止める" "1" "$(claude_calls)"
assert_contains "BLOCKED: 理由をコメントに残す" "$(cat "$GH_STUB_DIR/comment-50-1.md")" "BLOCKED: 本番の認証情報が要る"

# --- test 7: base が進んでコンフリクト → worker に解決させる -------------------
make_fixture t7
add_issue 60 "Conflict" OPEN "wt-loop" "x"
# worker が作業している間に origin/dev が進む (shared.txt を書き換える) 状況を再現する。
# loop は開始時に fetch するので、worktree 作成後 = worker の中で進める。
adv="$TMP/t7-adv"
git clone -q -b dev "$ORIGIN" "$adv"
cat >"$CLAUDE_STUB_DIR/step-1.sh" <<EOF
#!/usr/bin/env bash
set -e
printf 'mine\n' >shared.txt
git add -A
git -c user.email=w@example.com -c user.name=worker commit -qm implement
printf 'upstream\n' >"$adv/shared.txt"
git -C "$adv" -c user.email=u@example.com -c user.name=up commit -qam upstream
# worker の環境では push が塞がれている (環境 + PATH の shim) ので、上流役の push だけ両方外す
unset GIT_CONFIG_COUNT
"\$WT_LOOP_REAL_GIT" -C "$adv" push -q origin dev
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"実装した"}'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-1.sh"
cat >"$CLAUDE_STUB_DIR/step-2.sh" <<'EOF'
#!/usr/bin/env bash
set -e
printf 'resolved\n' >shared.txt
git add shared.txt
git -c user.email=w@example.com -c user.name=worker commit -qm "merge origin/dev"
printf '{"type":"result","subtype":"success","is_error":false,"result":"解決した"}\n'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-2.sh"
reviewer_step 3 PASS ok '[]'
out="$(loop)"
sd="$(state_dir 60)"
assert_contains "conflict: プロンプトにコンフリクトファイル" "$(cat "$CLAUDE_STUB_DIR/prompt-2.txt")" "コンフリクトした"
assert_contains "conflict: ファイル名を渡す" "$(cat "$CLAUDE_STUB_DIR/prompt-2.txt")" "shared.txt"
assert_eq "conflict: 解決後に merged" "merged" "$(cat "$sd/status" 2>/dev/null)"
assert_eq "conflict: origin/dev に解決結果が入る" "resolved" "$(git -C "$ORIGIN" show dev:shared.txt 2>/dev/null)"

# --- test 8: 未コミット / worker 異常終了 --------------------------------------
make_fixture t8
add_issue 70 "Dirty" OPEN "wt-loop" "x"
cat >"$CLAUDE_STUB_DIR/step-1.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >left.txt
printf '{"type":"result","subtype":"success","is_error":false,"result":"途中"}\n'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-1.sh"
cat >"$CLAUDE_STUB_DIR/step-2.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$CLAUDE_STUB_DIR/step-2.sh"
cat >"$CLAUDE_STUB_DIR/step-3.sh" <<'EOF'
#!/usr/bin/env bash
set -e
git add -A
git -c user.email=w@example.com -c user.name=worker commit -qm add
printf '{"type":"result","subtype":"success","is_error":false,"result":"コミットした"}\n'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-3.sh"
reviewer_step 4 PASS ok '[]'
out="$(loop --max-rounds 3)"
sd="$(state_dir 70)"
assert_contains "dirty: 未コミットを指摘する" "$(cat "$CLAUDE_STUB_DIR/prompt-2.txt")" "未コミットの変更が残っている"
assert_contains "dirty: ファイル名を渡す" "$(cat "$CLAUDE_STUB_DIR/prompt-2.txt")" "left.txt"
assert_contains "crash: 異常終了を指摘する" "$(cat "$CLAUDE_STUB_DIR/prompt-3.txt")" "正常に終了しなかった"
assert_eq "dirty/crash: 3 ラウンドで merged" "merged" "$(cat "$sd/status" 2>/dev/null)"

# --- test 9: CI 失敗 → 修正 → 同じ PR を更新 / no checks reported の再確認 -------
make_fixture t9
add_issue 80 "CI" OPEN "wt-loop" "x"
worker_step 1 a.txt v1
reviewer_step 2 PASS ok '[]'
worker_step 3 a.txt v2
reviewer_step 4 PASS ok '[]'
: >"$GH_STUB_DIR/checks-fail-once"
out="$(loop)"
sd="$(state_dir 80)"
assert_contains "CI 失敗: 指摘を worker に渡す" "$(cat "$CLAUDE_STUB_DIR/prompt-3.txt")" "CI が失敗した"
assert_eq "CI 失敗: PR は 1 回だけ作る" "1" "$(grep -c '^pr create' "$GH_STUB_DIR/gh.log")"
assert_eq "CI 失敗: 再 push 後にマージ" "merged" "$(cat "$sd/status" 2>/dev/null)"
assert_eq "CI 失敗: 2 回目の成果が origin に入る" "v2" "$(git -C "$ORIGIN" show dev:a.txt 2>/dev/null)"
make_fixture t9b
add_issue 81 "No checks" OPEN "wt-loop" "x"
worker_step 1 a.txt v1
reviewer_step 2 PASS ok '[]'
: >"$GH_STUB_DIR/checks-none-once"
out="$(loop)"
assert_eq "no checks: 一度待って再確認してから進む" "2" "$(grep -c '^pr checks' "$GH_STUB_DIR/gh.log")"
assert_eq "no checks: マージまで進む" "merged" "$(cat "$(state_dir 81)/status" 2>/dev/null)"

# --- test 10: gh pr merge 拒否 → エスカレーション (リトライしない) ---------------
make_fixture t10
add_issue 90 "Blocked merge" OPEN "wt-loop" "x"
worker_step 1 a.txt v1
reviewer_step 2 PASS ok '[]'
: >"$GH_STUB_DIR/merge-fail"
out="$(loop)"
assert_eq "merge 拒否: needs-human" "needs-human" "$(cat "$(state_dir 90)/status" 2>/dev/null)"
assert_eq "merge 拒否: merge は 1 回だけ試す" "1" "$(grep -c '^pr merge' "$GH_STUB_DIR/gh.log")"
assert_contains "merge 拒否: 理由をコメントする" "$(cat "$GH_STUB_DIR/comment-90-2.md")" "gh pr merge が拒否された"

# --- test 11: --stop / status / --max-issues ------------------------------------
make_fixture t11
add_issue 100 "First" OPEN "wt-loop" "x"
add_issue 101 "Second" OPEN "wt-loop" "x"
cat >"$CLAUDE_STUB_DIR/step-1.sh" <<EOF
#!/usr/bin/env bash
set -e
printf 'x\n' >a.txt
git add -A
git -c user.email=w@example.com -c user.name=worker commit -qm add
# 進行中に wt loop --stop が打たれた状況を再現する
(cd "$REPO" && env HOME="$TMP/home" PATH="$TMP/bin:$SAFE_PATH" WT_LOOP_STATE="$STATE_ROOT" "$WT" loop --stop >/dev/null 2>&1)
printf '{"type":"result","subtype":"success","is_error":false,"result":"ok"}\n'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-1.sh"
out="$(loop)"
assert_eq "stop: 今の issue を stopped にする" "stopped" "$(cat "$(state_dir 100)/status" 2>/dev/null)"
assert_eq "stop: 次の issue に進まない" "" "$(state_dir 101)"
assert_dir "$REPO/.claude/worktrees/100-first" "stop: worktree を残す"
out="$(loop status)"
assert_contains "status: issue ごとの状態を出す" "$out" "#100	stopped"
make_fixture t12
add_issue 110 "A" OPEN "wt-loop" "x"
add_issue 111 "B" OPEN "wt-loop" "x"
worker_step 1 a.txt v1
reviewer_step 2 PASS ok '[]'
out="$(loop --max-issues 1)"
assert_eq "max-issues: 1 件で止まる" "merged" "$(cat "$(state_dir 110)/status" 2>/dev/null)"
assert_eq "max-issues: 2 件目は始めない" "" "$(state_dir 111)"

# --- test 14: worker は push できない (環境で保証) / gh は無認証 ------------------
make_fixture t14
add_issue 120 "Sandbox" OPEN "wt-loop" "x"
cat >"$CLAUDE_STUB_DIR/step-1.sh" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >a.txt
git add -A
git -c user.email=w@example.com -c user.name=worker commit -qm add
# worker が push を試みても (allowlist をすり抜けても) 失敗すること
git push origin HEAD:evil1 >/dev/null 2>&1; echo "push1=$?" >>"$CLAUDE_STUB_DIR/push.log"
git -C . push "$(git remote get-url origin)" HEAD:evil2 >/dev/null 2>&1; echo "push2=$?" >>"$CLAUDE_STUB_DIR/push.log"
# 環境の塞ぎを -c や GIT_CONFIG_COUNT で外しても、PATH の shim が push を止める
git -c "url.$(git remote get-url origin).pushInsteadOf=$(git remote get-url origin)" push origin HEAD:evil3 >/dev/null 2>&1; echo "push3=$?" >>"$CLAUDE_STUB_DIR/push.log"
GIT_CONFIG_COUNT=0 git push origin HEAD:evil4 >/dev/null 2>&1; echo "push4=$?" >>"$CLAUDE_STUB_DIR/push.log"
# shim を外した素の git でも環境の塞ぎが効く
"$WT_LOOP_REAL_GIT" -C . push origin HEAD:evil5 >/dev/null 2>&1; echo "push5=$?" >>"$CLAUDE_STUB_DIR/push.log"
# alias / pushurl / send-pack / credential の上書き経路も shim が止める
git -c alias.p=push p origin HEAD:evil6 >/dev/null 2>&1; echo "push6=$?" >>"$CLAUDE_STUB_DIR/push.log"
git -c remote.origin.pushurl="$(git remote get-url origin)" push origin HEAD:evil7 >/dev/null 2>&1; echo "push7=$?" >>"$CLAUDE_STUB_DIR/push.log"
git send-pack "$(git remote get-url origin)" HEAD:refs/heads/evil8 >/dev/null 2>&1; echo "push8=$?" >>"$CLAUDE_STUB_DIR/push.log"
git -c credential.helper=store credential fill </dev/null >/dev/null 2>&1; echo "cred=$?" >>"$CLAUDE_STUB_DIR/push.log"
git -c core.pager=cat commit --allow-empty -qm "push という語を含むコミット" ; echo "commit=$?" >>"$CLAUDE_STUB_DIR/push.log"
git fetch -q origin dev; echo "fetch=$?" >>"$CLAUDE_STUB_DIR/push.log"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-1.sh"
reviewer_step 2 PASS ok '[]'
out="$(loop)"
assert_contains "sandbox: worker に pushInsteadOf を渡す" "$(cat "$CLAUDE_STUB_DIR/env-1.txt")" "pushInsteadOf"
assert_contains "sandbox: worker の gh を無認証にする" "$(cat "$CLAUDE_STUB_DIR/env-1.txt")" "GH_CONFIG_DIR="
assert_not_contains "sandbox: GH_TOKEN を渡さない" "$(cat "$CLAUDE_STUB_DIR/env-1.txt")" "GH_TOKEN="
assert_contains "sandbox: reviewer にも同じ環境" "$(cat "$CLAUDE_STUB_DIR/env-2.txt")" "pushInsteadOf"
assert_eq "sandbox: remote 名への push は shim が止める (exit 1)" "1" "$(grep -cx 'push1=1' "$CLAUDE_STUB_DIR/push.log")"
assert_contains "sandbox: URL 直指定の push も失敗する" "$(cat "$CLAUDE_STUB_DIR/push.log")" "push2=1"
assert_contains "sandbox: -c で pushInsteadOf を上書きしても shim が止める" "$(cat "$CLAUDE_STUB_DIR/push.log")" "push3=1"
assert_contains "sandbox: GIT_CONFIG_COUNT=0 でも shim が止める" "$(cat "$CLAUDE_STUB_DIR/push.log")" "push4=1"
assert_contains "sandbox: shim を外した実 git でも環境の塞ぎが効く" "$(cat "$CLAUDE_STUB_DIR/push.log")" "push5=128"
assert_contains "sandbox: push 以外の git は shim を素通りする" "$(cat "$CLAUDE_STUB_DIR/push.log")" "commit=0"
assert_contains "sandbox: -c alias 経由の push を止める" "$(cat "$CLAUDE_STUB_DIR/push.log")" "push6=1"
assert_contains "sandbox: -c pushurl の上書きを止める" "$(cat "$CLAUDE_STUB_DIR/push.log")" "push7=1"
assert_contains "sandbox: send-pack を止める" "$(cat "$CLAUDE_STUB_DIR/push.log")" "push8=1"
assert_contains "sandbox: -c credential.* の上書きを止める" "$(cat "$CLAUDE_STUB_DIR/push.log")" "cred=1"
assert_contains "sandbox: fetch は通る" "$(cat "$CLAUDE_STUB_DIR/push.log")" "fetch=0"
if git -C "$ORIGIN" for-each-ref 'refs/heads/evil*' | grep -q evil; then
  fail "sandbox: origin に worker の push が届かない"
else
  pass "sandbox: origin に worker の push が届かない"
fi
assert_eq "sandbox: driver 自身の push は通り merged になる" "merged" "$(cat "$(state_dir 120)/status" 2>/dev/null)"
assert_contains "sandbox: allowlist に bash / sh を入れない" "$(cat "$CLAUDE_STUB_DIR/argv-1.txt")" "Bash(git *)"
assert_not_contains "sandbox: allowlist に bash を入れない" "$(cat "$CLAUDE_STUB_DIR/argv-1.txt")" "Bash(bash *)"
assert_not_contains "sandbox: allowlist に gh を入れない" "$(cat "$CLAUDE_STUB_DIR/argv-1.txt")" "Bash(gh "

# --- test 14b: worker が書いた scripts/check と hook を driver の環境で走らせない --------
make_fixture t14b
add_issue 121 "Evil check" OPEN "wt-loop" "x"
cat >"$CLAUDE_STUB_DIR/step-1.sh" <<'EOF'
#!/usr/bin/env bash
# scripts/check に push を仕込み、pre-push hook も置く
cat >scripts/check <<'CHK'
#!/usr/bin/env bash
git push -q origin HEAD:refs/heads/evil-from-check >/dev/null 2>&1 && echo "pushed" >"${CHECK_LOG%/*}/evil-check.marker"
"$WT_LOOP_REAL_GIT" push -q origin HEAD:refs/heads/evil-from-check2 >/dev/null 2>&1 && echo "pushed" >"${CHECK_LOG%/*}/evil-check2.marker"
exit 0
CHK
mkdir -p .githooks
printf '#!/usr/bin/env bash\necho hooked >"${CHECK_LOG%%/*}/hook.marker"\nexit 0\n' >.githooks/pre-push
chmod +x .githooks/pre-push scripts/check
printf 'x\n' >a.txt
git add -A
git -c user.email=w@example.com -c user.name=worker commit -qm evil
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-1.sh"
reviewer_step 2 PASS ok '[]'
rm -f "$TMP/evil-check.marker" "$TMP/evil-check2.marker" "$TMP/hook.marker"
out="$(loop)"
if git -C "$ORIGIN" for-each-ref 'refs/heads/evil-from-check*' | grep -q evil; then
  fail "check sandbox: scripts/check からの push が origin に届かない"
else
  pass "check sandbox: scripts/check からの push が origin に届かない"
fi
assert_eq "check sandbox: check 自体は通り merged になる" "merged" "$(cat "$(state_dir 121)/status" 2>/dev/null)"
# worker が core.hooksPath を設定した場合は共有 config の変更として escalate する
make_fixture t14c
add_issue 122 "Hooks" OPEN "wt-loop" "x"
cat >"$CLAUDE_STUB_DIR/step-1.sh" <<'EOF'
#!/usr/bin/env bash
git config core.hooksPath .githooks
printf 'x\n' >a.txt
git add -A
git -c user.email=w@example.com -c user.name=worker commit -qm add
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-1.sh"
out="$(loop)"
assert_eq "config drift: needs-human にする" "needs-human" "$(cat "$(state_dir 122)/status" 2>/dev/null)"
assert_contains "config drift: 変更内容をコメントする" "$(cat "$GH_STUB_DIR/comment-122-1.md")" "core.hookspath=.githooks"
assert_eq "config drift: reviewer を呼ばずに止める" "1" "$(claude_calls)"

# --- test 15: needs-human の issue を番号指定で再開する (worktree と session を再利用) ---
make_fixture t15
add_issue 130 "Resume me" OPEN "wt-loop" "x"
cat >"$CLAUDE_STUB_DIR/step-1.sh" <<'EOF'
#!/usr/bin/env bash
printf 'half\n' >a.txt
git add -A
git -c user.email=w@example.com -c user.name=worker commit -qm half
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"**BLOCKED:** 仕様の判断が要る"}'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-1.sh"
out="$(loop)"
sd="$(state_dir 130)"
assert_eq "resume: 太字の BLOCKED も検出する" "needs-human" "$(cat "$sd/status" 2>/dev/null)"
first_session="$(cat "$sd/session-id")"
out="$(loop 130 --dry-run)"
assert_contains "resume: ラベルが付いたままなら再開しない" "$out" "skip #130: needs-human ラベル"
out="$(loop --dry-run)"
assert_not_contains "resume: ラベル選択では進行中の issue を拾わない" "$out" "#130 Resume me"
# 人間がラベルを外して番号で再投入する
jq 'map(if .number == 130 then .labels = [{"name":"wt-loop"}] else . end)' "$GH_STUB_DIR/issues.json" >"$GH_STUB_DIR/issues.json.tmp" && mv "$GH_STUB_DIR/issues.json.tmp" "$GH_STUB_DIR/issues.json"
worker_step 2 a.txt full
reviewer_step 3 PASS ok '[]'
out="$(loop 130)"
assert_contains "resume: 残っている worktree を再利用する" "$out" "再開 (worktree 130-resume-me"
assert_contains "resume: 前回の session を --resume する" "$(tr '\n' ' ' <"$CLAUDE_STUB_DIR/argv-2.txt")" "--resume $first_session "
assert_contains "resume: 続きから進める指示を渡す" "$(cat "$CLAUDE_STUB_DIR/prompt-2.txt")" "前回の run は途中で止まった"
assert_eq "resume: 完走して merged" "merged" "$(cat "$sd/status" 2>/dev/null)"
assert_eq "resume: 両方のコミットが origin に入る" "full" "$(git -C "$ORIGIN" show dev:a.txt 2>/dev/null)"
# session が残っていない (resume が No conversation found) ときは、issue 本文込みの新 session で続ける
make_fixture t15b
add_issue 131 "Lost session" OPEN "wt-loop" "## 受け入れ条件
- [ ] 本文が新しい session に渡る"
cat >"$CLAUDE_STUB_DIR/step-1.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"**BLOCKED**: 一旦止める"}'
EOF
chmod +x "$CLAUDE_STUB_DIR/step-1.sh"
out="$(loop)"
assert_eq "resume: **BLOCKED**: の形も検出する" "needs-human" "$(cat "$(state_dir 131)/status" 2>/dev/null)"
jq 'map(if .number == 131 then .labels = [] else . end)' "$GH_STUB_DIR/issues.json" >"$GH_STUB_DIR/issues.json.tmp" && mv "$GH_STUB_DIR/issues.json.tmp" "$GH_STUB_DIR/issues.json"
cat >"$CLAUDE_STUB_DIR/step-2.sh" <<'EOF'
#!/usr/bin/env bash
echo "No conversation found with session ID: x" >&2
exit 1
EOF
chmod +x "$CLAUDE_STUB_DIR/step-2.sh"
worker_step 3 a.txt v1
reviewer_step 4 PASS ok '[]'
out="$(loop 131)"
assert_contains "resume: session 再作成時は issue 本文を渡す" "$(cat "$CLAUDE_STUB_DIR/prompt-3.txt")" "本文が新しい session に渡る"
assert_contains "resume: session 再作成時は引き継ぎも渡す" "$(cat "$CLAUDE_STUB_DIR/prompt-3.txt")" "## 前回からの引き継ぎ"
assert_contains "resume: 新しい --session-id で起動する" "$(cat "$CLAUDE_STUB_DIR/argv-3.txt")" "--session-id"
assert_eq "resume: 完走して merged" "merged" "$(cat "$(state_dir 131)/status" 2>/dev/null)"

# --- test 16: ラベル付きの子 issue も依存判定を受ける (一覧は新しい順) ----------
make_fixture t16
add_issue 4 "Parent" OPEN "wt-loop" "## 子タスク
- [ ] #5 A
- [ ] #6 B（#5 のあと）
- [ ] #7 認証 (OAuth) のあとの画面（#5, #6 のあと）"
add_issue 5 "A" OPEN "wt-loop" "親 issue: #4"
add_issue 6 "B" OPEN "wt-loop" "親 issue: #4"
add_issue 7 "C" OPEN "wt-loop" "親 issue: #4"
add_issue 8 "Orphan child" OPEN "wt-loop" "## 背景
親 issue: #9"
add_issue 9 "Unlabelled parent" OPEN "" "## 子タスク
\`\`\`
- [ ] #99 コードフェンスの中は読まない
# 見出しに見える行
\`\`\`
- [ ] #8 Orphan child（#5 のあと）"
out="$(loop --dry-run)"
assert_contains "deps: 依存の無い子は対象" "$out" "#5 A"
assert_contains "deps: ラベル付きでも依存が OPEN なら待つ" "$out" "skip #6: 依存 #5 が未完了"
assert_contains "deps: タイトル内の「のあと」に惑わされず末尾の表記を読む" "$out" "skip #7: 依存 #5 が未完了"
assert_contains "deps: 単体の子は本文の親参照から依存を引く" "$out" "skip #8: 依存 #5 が未完了"
assert_not_contains "deps: コードフェンス内の行は子にしない" "$out" "#99"
assert_eq "deps: 対象は #5 だけ" "1" "$(printf '%s\n' "$out" | grep -c '^  #')"

# --- test 17: マージで依存が解けた子を同じ run で拾う (再選択) ---------------------
make_fixture t17
add_issue 5 "A" OPEN "wt-loop" "親 issue: #4"
add_issue 6 "B" OPEN "wt-loop" "親 issue: #4"
add_issue 4 "Parent" OPEN "" "## 子タスク
- [ ] #5 A
- [ ] #6 B（#5 のあと）"
worker_step 1 a.txt v1
reviewer_step 2 PASS ok '[]'
worker_step 3 b.txt v1
reviewer_step 4 PASS ok '[]'
out="$(loop)"
assert_contains "reselect: 1 巡目は #5 だけ" "$out" "skip #6: 依存 #5 が未完了"
assert_contains "reselect: 2 巡目で #6 を拾う" "$out" "対象 (2 巡目)"
assert_eq "reselect: #6 も merged" "merged" "$(cat "$(state_dir 6)/status" 2>/dev/null)"
assert_contains "reselect: 合計 2 件" "$out" "処理 2 件 / マージ 2 件"
# GitHub 側の close が遅れても、この run でマージした issue は拾い直さない
make_fixture t17b
add_issue 5 "A" OPEN "wt-loop" "x"
worker_step 1 a.txt v1
reviewer_step 2 PASS ok '[]'
export GH_STUB_NO_AUTOCLOSE=1
out="$(loop)"
unset GH_STUB_NO_AUTOCLOSE
assert_contains "reselect: Fixes で閉じなくても明示的に閉じる" "$(cat "$GH_STUB_DIR/gh.log")" "issue close 5"
assert_contains "reselect: 同じ issue を拾い直さない" "$out" "処理 1 件 / マージ 1 件"

# --- test 18: worktree を作れない issue は needs-human にして次へ進む -------------
make_fixture t18
add_issue 140 "Broken" OPEN "wt-loop" "x"
add_issue 141 "Fine" OPEN "wt-loop" "x"
mkdir -p "$REPO/.claude/worktrees/140-broken"
printf 'junk\n' >"$REPO/.claude/worktrees/140-broken/junk"
worker_step 1 a.txt v1
reviewer_step 2 PASS ok '[]'
out="$(loop)"
assert_eq "wt new 失敗: needs-human にする" "needs-human" "$(cat "$(state_dir 140)/status" 2>/dev/null)"
assert_contains "wt new 失敗: 理由をコメントする" "$(cat "$GH_STUB_DIR/comment-140-1.md")" "worktree を作れなかった"
assert_eq "wt new 失敗: 次の issue に進む" "merged" "$(cat "$(state_dir 141)/status" 2>/dev/null)"

# --- test 19: worker がすぐ異常終了したら loop を止める (キュー全体を needs-human にしない) ---
make_fixture t19
add_issue 150 "First" OPEN "wt-loop" "x"
add_issue 151 "Second" OPEN "wt-loop" "x"
cat >"$CLAUDE_STUB_DIR/step-1.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"usage limit reached"}'
exit 1
EOF
chmod +x "$CLAUDE_STUB_DIR/step-1.sh"
out="$(INFRA_SECS=60 loop; echo "rc=$?")"
assert_eq "infra: status が failed" "failed" "$(cat "$(state_dir 150)/status" 2>/dev/null)"
assert_contains "infra: loop を止める" "$out" "claude か gh が動いていない疑い"
assert_eq "infra: 次の issue を始めない" "" "$(state_dir 151)"
assert_not_contains "infra: needs-human は付けない" "$(cat "$GH_STUB_DIR/gh.log")" "add-label needs-human"
assert_contains "infra: 終了コードは 1" "$out" "rc=1"
assert_contains "infra: 再開は番号指定と案内する" "$out" "wt loop 150 と番号指定で再開"
# 直ったら番号指定で再開できる
worker_step 2 a.txt v1
reviewer_step 3 PASS ok '[]'
out="$(loop 150)"
assert_eq "infra: 番号指定で再開して merged" "merged" "$(cat "$(state_dir 150)/status" 2>/dev/null)"

# --- test 20: CI 待ちの上限 / workflow がある repo では no checks を待ち続ける -------
make_fixture t20
mkdir -p "$REPO/.github/workflows"
printf 'name: ci\n' >"$REPO/.github/workflows/ci.yml"
git -C "$REPO" add -A
git -C "$REPO" commit -qm ci
git -C "$REPO" push -q origin dev
add_issue 160 "Slow CI" OPEN "wt-loop" "x"
worker_step 1 a.txt v1
reviewer_step 2 PASS ok '[]'
: >"$GH_STUB_DIR/checks-none"
out="$(WT_LOOP_CI_TIMEOUT=1 loop)"
assert_eq "CI 上限: needs-human にする" "needs-human" "$(cat "$(state_dir 160)/status" 2>/dev/null)"
assert_contains "CI 上限: 理由をコメントする" "$(cat "$GH_STUB_DIR/comment-160-2.md")" "CI の完了を 1s 待っても終わらなかった"
assert_not_contains "CI 上限: check 無しのままマージしない" "$(cat "$GH_STUB_DIR/gh.log")" "pr merge"
assert_contains "CI 上限: pr checks に --fail-fast" "$(cat "$GH_STUB_DIR/gh.log")" "--watch --fail-fast"

# --- test 21: 同じ repo で loop を二重に起動しない ---------------------------------
make_fixture t21
add_issue 170 "Locked" OPEN "wt-loop" "x"
sd_root="$STATE_ROOT/t21-$(printf '%s' "$REPO" | cksum | awk '{print $1}')"
mkdir -p "$sd_root"
printf '%s\n' "$$" >"$sd_root/lock"
out="$(loop)"
assert_contains "lock: 実行中の loop があれば止まる" "$out" "別の wt loop (pid $$) が実行中"
assert_eq "lock: claude を呼ばない" "0" "$(claude_calls)"
rm -f "$sd_root/lock"

# --- test 13: 引数の検証 ---------------------------------------------------------
out="$(loop --max-rounds 0)"
assert_contains "args: --max-rounds 0 は拒否" "$out" "1 以上の整数"
out="$(loop abc)"
assert_contains "args: 番号でない引数は拒否" "$out" "issue 番号として解釈できない"
out="$(loop --bogus)"
assert_contains "args: 不明なオプションは拒否" "$out" "不明なオプション"

if [ "$FAILED" -eq 0 ]; then
  echo "all loop tests passed"
else
  echo "some loop tests FAILED"
  exit 1
fi
