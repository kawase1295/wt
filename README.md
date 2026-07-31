# wt

git worktree と [herdr](https://github.com/) workspace を一体で管理し、並列開発セッションをワンコマンドで立ち上げる bash CLI。

`wt new <task>` を打つと、worktree を切り、gitignore されて worktree に入らないファイル（`.env` など）を本体から補完し、herdr workspace を開いて Claude Code を起動するところまでを一息で行う。`--prompt` で起動する Claude に初期プロンプト（作業内容や実装プラン）を渡せる。herdr が無い環境では素の `git worktree` 作成だけにフォールバックするので、herdr は必須ではない。

## 特徴

- **一体管理** — worktree・ブランチ・herdr workspace・エージェント起動を 1 コマンドに集約
- **欠落ファイルの補完** — `.worktreeinclude` に列挙した gitignore 済みファイルを実体コピー、本体の `.env` を symlink、`.claude/settings.local.json` をコピー。fresh checkout ではテストが動かない問題を解消する
- **作業の受け渡し** — `--prompt` / `--prompt-file` で worktree 側の Claude Code に初期プロンプトを渡す。`/wt` などの slash command skill を同梱
- **repo 固有の準備を委譲** — DB コピーや native rebuild などは repo 側の `scripts/worktree-setup` に委ねる契約
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

同梱の `install.sh` は配置に加えて Claude Code skill（後述）も `~/.claude/skills/` に入れる。

```bash
./install.sh                     # ~/.local/bin/wt + ~/.claude/skills/ に配置
PREFIX=~/bin ./install.sh        # 配置先を変える
WT_INSTALL_SKILLS=0 ./install.sh # skill を配置しない
```

skill は wt の管理物として毎回上書きされる。ローカルで skill を改変している場合は `WT_INSTALL_SKILLS=0` で守る。

## 使い方

対象リポジトリ内の任意の場所から実行する。

```bash
wt new <task> [--base <ref>] [--no-claude] [--prompt <text>|--prompt-file <path>]
    worktree を <repo>/.claude/worktrees/<task>（ブランチ worktree-<task>）に作り、
    herdr workspace を開き、bootstrap 後に Claude Code を起動する
    （base 省略時は本体の現在ブランチ）。
    --prompt / --prompt-file は起動する Claude への初期プロンプト（要 herdr）。
    claude には既定で --model opus --permission-mode auto を渡す
    （WT_CLAUDE_ARGS で差し替え、空文字でフラグ無し。空白を含む値は不可）

wt bootstrap [<path>]
    既存 worktree に、gitignore されて入らないファイルを補完する。
    Claude Code が作る .claude/worktrees/* にも使える

wt open <task>
    既存 worktree を herdr workspace として開き直す

wt list
    worktree と herdr workspace の対応を一覧表示

wt merge [<task>]
    ブランチ worktree-<task> を本体の現在ブランチへマージする。
    worktree 内から task 省略で自分を対象にできる。コンフリクトは本体に残して中断

wt rm [<task>] [--force]
    worktree / workspace / ブランチを削除する（未コミット変更があれば中断）。
    worktree 内から task 省略で自分を片付けられる
```

### 例

```bash
# main から feature ブランチの worktree を切って作業を始める
wt new fix-login

# 初期プロンプト付きで worktree の Claude Code を起動する
wt new fix-login --prompt "ログイン失敗時のリトライを実装して。終わったらコミットすること"

# 実装プランをファイルで渡す（長文・改行入り向け）
wt new fix-login --prompt-file /tmp/plan.md

# 特定の base から分岐、Claude Code は起動しない
wt new spike-cache --base release/2.0 --no-claude

# 別の並列作業に切り替える / 作業一覧を見る
wt open fix-login
wt list

# worktree の中から: 成果を本体に取り込み、自分を片付ける
wt merge   # ブランチを本体の現在ブランチへマージ
wt rm      # worktree / workspace / ブランチを削除して workspace を閉じる
```

worktree は Claude Code の native worktree と同じ `<repo>/.claude/worktrees/<task名>` に、ブランチ `worktree-<task名>` で作られる。native（`claude --worktree`）と同じ実体を指すので、native で作った worktree も `wt open` / `wt bootstrap` / `wt rm` で扱える。`WT_HOME` を設定すると従来の集約置き場 `$WT_HOME/<repo名>/<task名>` に作る。

## 仕組み

### bootstrap の分担

fresh な worktree は本体の gitignore 済みファイルを持たないため、テストやアプリが動かないことがある。`wt` はこれを 2 段で補完する。

**共通処理（`wt` 本体）**

1. `.worktreeinclude`（repo root、要コミット、gitignore 構文）に列挙された gitignore 済みファイルを本体から実体コピー（既存ファイルは上書きしない）
2. 本体の `.env` を worktree へ symlink（実体ファイルが既にあれば触らない。`.worktreeinclude` に `.env` があればコピーが優先される）
3. `.claude/settings.local.json` をコピー（Claude Code の許可設定の引き継ぎ）
4. repo フックがあれば委譲、無ければ lockfile から検出した package manager で依存インストール
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

[`skills/`](skills/) に 7 つの skill を同梱しており、`install.sh` が `~/.claude/skills/` に配置する。dev（本体 checkout）側のセッションから作業を worktree に投げ、worktree 側のセッションでレビュー・取り込み・片付けを完結させる。

| skill | 実行する側 | 役割 |
| --- | --- | --- |
| `/wt <作業内容>` | dev | worktree 名を生成し、作業内容を初期プロンプトとして worktree + Claude Code を起動 |
| `/wt-detail <作業内容>` | dev | コードベースを調査して実装プランを作り、プランを初期プロンプトとして worktree に渡す |
| `/wt-review` | worktree | マージ前に diff からレビュー用 HTML を生成してブラウザで開き、承認を待つ |
| `/wt-merge` | worktree | 自分のブランチを本体の現在ブランチへマージ（コンフリクトは報告して停止） |
| `/wt-clean` | worktree | 未コミット・未マージを検査し、クリーンなら自分の worktree を片付けて workspace を閉じる |
| `worktree-parallel` | 両方 | `wt` と native worktree の使い分け方針・`.worktreeinclude` の契約（[skills/worktree-parallel/SKILL.md](skills/worktree-parallel/SKILL.md)） |
| `local-artifact` | 両方 | Artifact と同一の設計規約で HTML を作り、claude.ai に publish せずローカル公開する契約（`/wt-review` が参照） |

典型的なフロー:

```
dev 側:      /wt ログイン画面のバリデーション修正
              → worktree + workspace が開き、Claude が作業内容付きで起動する
worktree 側: (実装・コミット) → /wt-review → (ユーザーがレビュー・承認) → /wt-merge → /wt-clean
              → 本体に取り込まれ、worktree / workspace / ブランチが消えて閉じる
```

## 既知の注意点

- worktree は `<repo>/.claude/worktrees/` に作られるため、本体 checkout の `git status` に `.claude/` が untracked として現れる（Claude Code の native worktree でも同じ）。`git add .` で worktree の実体を巻き込まないよう注意。気になる場合は本体の `.gitignore` か `.git/info/exclude` に `.claude/worktrees/` を加える。
- `~/.npmrc` に `ignore-scripts=true` があると、`npm ci` だけでは native addon（better-sqlite3 等）がビルドされない。フックで rebuild するか、本体のビルド済み `.node` をコピーする。
- 本体 checkout の未コミット変更は worktree に入らない（worktree はコミット済み ref から分岐する）。
- `.worktreeinclude` のコピーではディレクトリパターン（`secrets/`）がそのまま使える。フックで symlink する場合のみ末尾スラッシュ無し（`secrets`）で書く。
- `.worktreeinclude` の否定パターン `!` は、親ディレクトリごと除外した配下を再 include できない（gitignore の仕様）。`secrets/` + `!secrets/x` は効かず、`secrets/*` + `!secrets/x` と書く。
- 空ディレクトリと、エントリ自体が相対 symlink のファイルは正しく持ち込めない（git が列挙しない / リンク先が worktree 内で切れる）。
- `wt merge` のコンフリクトは本体 checkout の working tree に発生する。解決するか `git merge --abort` で戻すまで本体が merge 中の状態になる。

## ライセンス

[MIT](LICENSE)
