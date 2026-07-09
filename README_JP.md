# wt

git worktree と [herdr](https://github.com/) workspace を一体で管理し、並列開発セッションをワンコマンドで立ち上げる bash CLI。

`wt new <task>` を打つと、worktree を切り、gitignore されて worktree に入らないファイル（`.env` など）を本体から補完し、herdr workspace を開いて Claude Code を起動するところまでを一息で行う。herdr が無い環境では素の `git worktree` 作成だけにフォールバックするので、herdr は必須ではない。

## 特徴

- **一体管理** — worktree・ブランチ・herdr workspace・エージェント起動を 1 コマンドに集約
- **欠落ファイルの補完** — 本体の `.env` を symlink、`.claude/settings.local.json` をコピー。fresh checkout ではテストが動かない問題を解消する
- **repo 固有の準備を委譲** — secrets の symlink や DB コピー、native rebuild などは repo 側の `scripts/worktree-setup` に委ねる契約
- **graceful fallback** — herdr サーバに接続できなければ `git worktree` の作成だけで続行する

## 前提

| ツール | 要否 | 用途 |
| --- | --- | --- |
| bash 4+ | 必須 | 本体 |
| git | 必須 | worktree 操作 |
| [herdr](https://github.com/) | 任意 | workspace / エージェント起動（無ければ git worktree のみ） |
| jq | herdr 使用時に必須 | herdr の JSON 出力パース |

## インストール

`wt` は単一ファイル。PATH の通ったディレクトリに置くだけで動く。

```bash
git clone https://github.com/kawase1295/wt.git
install -m 755 wt/wt ~/.local/bin/wt   # ~/.local/bin が PATH にある前提
```

同梱の `install.sh` でも同じことができる。

```bash
./install.sh          # 既定で ~/.local/bin/wt に配置
PREFIX=~/bin ./install.sh   # 配置先を変える
```

## 使い方

対象リポジトリ内の任意の場所から実行する。

```bash
wt new <task> [--base <ref>] [--no-claude]
    worktree を ~/.herdr/worktrees/<repo>/<task> に作り、herdr workspace を
    開き、bootstrap 後に Claude Code を起動する（base 省略時は本体の現在ブランチ）

wt bootstrap [<path>]
    既存 worktree に、gitignore されて入らないファイルを補完する。
    Claude Code が作る .claude/worktrees/* にも使える

wt open <task>
    既存 worktree を herdr workspace として開き直す

wt list
    worktree と herdr workspace の対応を一覧表示

wt rm <task> [--force]
    worktree / workspace / ブランチを削除する（未コミット変更があれば中断）
```

### 例

```bash
# main から feature ブランチの worktree を切って作業を始める
wt new fix-login

# 特定の base から分岐、Claude Code は起動しない
wt new spike-cache --base release/2.0 --no-claude

# 別の並列作業に切り替える
wt open fix-login

# 作業一覧を見る
wt list

# 終わった worktree を片付ける（マージ済みブランチも削除）
wt rm fix-login
```

## 設定

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `WT_HOME` | `~/.herdr/worktrees` | worktree のルートディレクトリ |
| `WT_LANG` | `en` | UI 言語 (`en` または `ja`) |

シェルプロファイルで `WT_LANG=ja` を設定すると、全メッセージが日本語になる。

```bash
export WT_LANG=ja
```

worktree は herdr の標準位置 `~/.herdr/worktrees/<repo名>/<task名>` に作られる。`WT_HOME` 環境変数で変更できる。

## 仕組み

### bootstrap の分担

fresh な worktree は本体の gitignore 済みファイルを持たないため、テストやアプリが動かないことがある。`wt` はこれを 2 段で補完する。

**共通処理（`wt` 本体）**

1. 本体の `.env` を worktree へ symlink（実体ファイルが既にあれば触らない）
2. `.claude/settings.local.json` をコピー（Claude Code の許可設定の引き継ぎ）
3. repo フックがあれば委譲、無ければ lockfile から検出した package manager で依存インストール
   （npm / pnpm / yarn / bun / uv に対応）

**repo 固有処理（repo の `scripts/worktree-setup`、実行可能ファイル）**

コピーで表せない補完＝依存インストール・環境 symlink 再生成・native rebuild は repo 側に置く。フックは次の環境で呼ばれる。

- cwd = worktree
- `WT_MAIN_ROOT` = 本体 checkout の絶対パス
- `WT_TARGET` = worktree の絶対パス

フックが存在すると依存インストールもフック側の責任になる（`wt` は install しない）。

### repo フックの例

```bash
#!/usr/bin/env bash
# scripts/worktree-setup — worktree に repo 固有の欠落を補完する
set -euo pipefail

# gitignore された secrets を本体から symlink 共有する
ln -sfn "$WT_MAIN_ROOT/secrets" "$WT_TARGET/secrets"

# 依存インストール（フックがあると wt 本体は install しないので自分でやる）
npm ci --prefer-offline --no-audit --no-fund

# native addon を含む場合の再ビルド例
# npm rebuild better-sqlite3 --ignore-scripts=false --foreground-scripts
```

## Claude Code 連携

Claude Code で並列開発するときの `wt` と native worktree（`claude --worktree` / subagent isolation）の使い分け方針を [`docs/claude-code-skill.md`](docs/claude-code-skill.md) にまとめてある。Claude Code の skill（`~/.claude/skills/`）として置くとそのまま使える。

## 既知の注意点

- `~/.npmrc` に `ignore-scripts=true` があると、`npm ci` だけでは native addon（better-sqlite3 等）がビルドされない。フックで rebuild するか、本体のビルド済み `.node` をコピーする。
- 本体 checkout の未コミット変更は worktree に入らない（worktree はコミット済み ref から分岐する）。
- gitignore で共有ディレクトリを無視する場合、symlink には末尾スラッシュ付きパターン（`secrets/`）が一致しない。`secrets` のように書く。

## ライセンス

[MIT](LICENSE)
