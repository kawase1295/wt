#!/usr/bin/env bash
# wt をインストールする。既定で ~/.local/bin/wt に配置する。
# 配置先を変えるには PREFIX を渡す: PREFIX=~/bin ./install.sh
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt"

mkdir -p "$PREFIX"
install -m 755 "$src" "$PREFIX/wt"
echo "[install] $PREFIX/wt に配置した"

# Claude Code skill を配置する (WT_INSTALL_SKILLS=0 でスキップ)。
# skill は wt の管理物として常に上書きする。
repo_root="$(dirname "$src")"
if [ "${WT_INSTALL_SKILLS:-1}" = "1" ] && [ -d "$repo_root/skills" ]; then
  skills_dst="${WT_SKILLS_DIR:-$HOME/.claude/skills}"
  for d in "$repo_root/skills"/*/; do
    name="$(basename "$d")"
    mkdir -p "$skills_dst/$name"
    install -m 644 "$d/SKILL.md" "$skills_dst/$name/SKILL.md"
    echo "[install] skill: $skills_dst/$name/SKILL.md"
  done
fi

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "[install] 注意: $PREFIX が PATH に無い。シェルの設定に追加してください" ;;
esac
