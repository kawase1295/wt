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
# skill は wt の管理物として常に上書きする。SKILL.md 以外の同梱物
# (wt-review の assets/ など) も要るのでディレクトリごとコピーする。
# repo から削除されたファイルが配置先に残らないよう、毎回作り直す。
# 配置先の skill ディレクトリに自分のファイルを置かないこと。
repo_root="$(dirname "$src")"
if [ "${WT_INSTALL_SKILLS:-1}" = "1" ] && [ -d "$repo_root/skills" ]; then
  skills_dst="${WT_SKILLS_DIR:-$HOME/.claude/skills}"
  for d in "$repo_root/skills"/*/; do
    name="$(basename "$d")"
    rm -rf "${skills_dst:?}/${name:?}"
    mkdir -p "$skills_dst/$name"
    cp -R "$d." "$skills_dst/$name/"
    echo "[install] skill: $skills_dst/$name/"
  done
fi

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "[install] 注意: $PREFIX が PATH に無い。シェルの設定に追加してください" ;;
esac
