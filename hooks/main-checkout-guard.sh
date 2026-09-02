#!/usr/bin/env bash
# 本体 checkout でのブランチ切替を ask に落とす PreToolUse hook。
#
# wt の運用は「タスク = issue = ブランチ = PR」を worktree に 1:1 で対応させる。
# 本体 checkout でブランチを切って直接作業すると対応が崩れ、レビューゲート
# (/wt-review) も worktree セッションも通らない。skill の文章は skill が起動して
# 初めて読まれるので、起動しない経路 (「issue を確認して」からそのまま実装に
# 流れる等) には効かない。そのため Bash の実行前に静的に検査する。
#
# deny ではなく ask にしている。本体のブランチを動かす正当な用途 (dev / main の
# 行き来、rebase、緊急のブランチ確認) を詰まらせないため。
#
# 素通しする条件:
#   - WT_GUARD_DISABLE=1
#   - cwd が git work tree でない / linked worktree の中
#   - 切替先が許可ブランチ (origin/HEAD の default branch + WT_GUARD_ALLOW_BRANCHES)
#   - git checkout -- <path> などのファイル復元、ブランチ以外への checkout
#   - JSON を読む手段 (jq / python3) が無い
#
# ガードは fail-open にする。判定できない入力でブロックすると、hook の不調が
# そのまま Bash 全体の停止になるため。
set -uo pipefail

[ "${WT_GUARD_DISABLE:-0}" = "1" ] && exit 0

input="$(cat)"

# 大半の Bash 呼び出しはここで抜ける (JSON パーサを起動しない)。
case "$input" in
  *checkout* | *switch*) ;;
  *) exit 0 ;;
esac

# cwd と tool_input.command を 1 回の起動で取り出す。
# 1 行目が cwd、2 行目以降が command (command には改行が入りうる)。
read_fields() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r '(.cwd // ""), (.tool_input.command // "")' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
ti = d.get("tool_input")
cmd = ti.get("command") if isinstance(ti, dict) else ""
print(d.get("cwd") or "")
print(cmd if isinstance(cmd, str) else "")
' 2>/dev/null
  fi
}

parsed="$(read_fields)"
[ -n "$parsed" ] || exit 0
cwd="$(printf '%s\n' "$parsed" | head -n 1)"
cmd="$(printf '%s\n' "$parsed" | tail -n +2)"
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"
[ -d "$cwd" ] || exit 0

git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# linked worktree は素通し。本体 checkout だけを対象にする。
git_dir="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
common_dir="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || exit 0
case "$common_dir" in
  /*) ;;
  *) common_dir="$(cd "$cwd" && cd "$common_dir" 2>/dev/null && pwd)" || exit 0 ;;
esac
[ "$git_dir" = "$common_dir" ] || exit 0

# 許可ブランチ。default branch は remote 名 origin を前提に origin/HEAD から引く
# (他の remote 名なら既定の名前だけで判定する)。
allow_list="${WT_GUARD_ALLOW_BRANCHES-main,master,dev}"
default_branch="$(git -C "$cwd" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)"
default_branch="${default_branch#origin/}"

is_allowed() { # branch
  local b="$1" a
  [ -n "$b" ] || return 1
  [ -n "$default_branch" ] && [ "$b" = "$default_branch" ] && return 0
  local IFS=,
  # shellcheck disable=SC2086  # カンマ区切りを分割するための意図的な word splitting
  for a in $allow_list; do
    [ -n "$a" ] && [ "$b" = "$a" ] && return 0
  done
  return 1
}

unquote() { # 前後の同一クォートを 1 組だけ剥がす
  local s="$1"
  case "$s" in
    \'*\') s="${s#\'}" && s="${s%\'}" ;;
    \"*\") s="${s#\"}" && s="${s%\"}" ;;
  esac
  printf '%s' "$s"
}

# セグメントがブランチ切替なら、その切替先を stdout に出して 0 を返す。
branch_target() { # segment
  local seg="$1" tok=() i n w sub create=0 detach=0 track=0 target=""
  read -ra tok <<<"$seg"
  n=${#tok[@]}
  [ "$n" -gt 0 ] || return 1

  w="$(unquote "${tok[0]}")"
  case "$w" in
    git | */git) ;;
    *) return 1 ;;
  esac

  # git 自身のグローバルオプションを読み飛ばしてサブコマンドまで進む。
  i=1
  while [ "$i" -lt "$n" ]; do
    w="$(unquote "${tok[$i]}")"
    case "$w" in
      -C | -c | --git-dir | --work-tree | --namespace | --exec-path) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 1
  sub="$(unquote "${tok[$i]}")"
  case "$sub" in
    checkout | switch) ;;
    *) return 1 ;;
  esac

  # 切替先を拾う。-- 以降は path なのでファイル復元とみなす。
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    w="$(unquote "${tok[$i]}")"
    case "$w" in
      --) return 1 ;;
      -b | -B)
        [ "$sub" = checkout ] || { i=$((i + 1)) && continue; }
        create=1 && i=$((i + 1))
        [ "$i" -lt "$n" ] || return 1
        target="$(unquote "${tok[$i]}")"
        break
        ;;
      -c | -C)
        [ "$sub" = switch ] || { i=$((i + 1)) && continue; }
        create=1 && i=$((i + 1))
        [ "$i" -lt "$n" ] || return 1
        target="$(unquote "${tok[$i]}")"
        break
        ;;
      --detach | -d) detach=1 && i=$((i + 1)) ;;
      --track | -t) track=1 && i=$((i + 1)) ;;
      -) target="-" && break ;;
      -*) i=$((i + 1)) ;;
      *) target="$w" && break ;;
    esac
  done
  [ -n "$target" ] || return 1

  # `-` は直前ブランチ。実名に解決してから許可判定にかける。
  if [ "$target" = "-" ]; then
    target="$(git -C "$cwd" rev-parse --abbrev-ref '@{-1}' 2>/dev/null)" || return 1
    [ -n "$target" ] || return 1
  fi

  # 新規作成でも detach でも --track でもないなら、ブランチと確認できたときだけ
  # 切替とみなす (`git checkout <path>` のファイル復元や detached checkout を
  # 巻き込まない)。ローカルに無くても remote に同名があれば、git は追跡ブランチを
  # 作って切り替えるので (DWIM) それも切替として扱う。
  if [ "$create" -eq 0 ] && [ "$detach" -eq 0 ] && [ "$track" -eq 0 ]; then
    if ! git -C "$cwd" show-ref --verify --quiet "refs/heads/$target"; then
      [ -n "$(git -C "$cwd" for-each-ref --format='%(refname)' "refs/remotes/*/$target" 2>/dev/null)" ] || return 1
    fi
  fi

  printf '%s' "$target"
}

# 複合コマンドを分解する。区切り文字はすべて改行に潰す
# (クォート内の区切りも割れるが、誤検出しても出るのは ask なので害はない)。
hit=""
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  target="$(branch_target "$seg")" || continue
  is_allowed "$target" && continue
  hit="$target"
  break
done < <(printf '%s\n' "$cmd" | tr ';|&' '\n')

[ -n "$hit" ] || exit 0

# reason は JSON の文字列に埋めるので、壊す文字を落としてから使う。
# shellcheck disable=SC1003  # '"\\' は二重引用符とバックスラッシュの 2 文字を落とす指定
safe="$(printf '%s' "$hit" | tr -d '"\\' | tr -d '[:cntrl:]' | cut -c 1-80)"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"本体 checkout でブランチ「%s」に切り替えようとしています。worktree で作業するなら dev 側セッションで /wt を使ってください。本体のブランチを動かす必要があるときだけ許可してください。"}}\n' "$safe"
exit 0
