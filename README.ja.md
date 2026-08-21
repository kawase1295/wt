# wt

> ワンコマンドで git worktree + [herdr](https://herdr.dev) workspace + Claude Code セッション。

[![ci](https://github.com/kawase1295/wt/actions/workflows/ci.yml/badge.svg)](https://github.com/kawase1295/wt/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![shell](https://img.shields.io/badge/shell-bash-lightgrey.svg)](wt)

**言語: [English](README.md) | 日本語**

git worktree と [herdr](https://herdr.dev) workspace を一体で管理し、並列開発セッションをワンコマンドで立ち上げる bash CLI。

`wt new <task>` を打つと、worktree を切り、gitignore されて worktree に入らないファイル（`.env` など）を本体から補完し、herdr workspace を開いて Claude Code を起動するところまでを一息で行う。`--prompt` で起動する Claude に初期プロンプト（作業内容や実装プラン）を渡せる。herdr が無い環境では素の `git worktree` 作成だけにフォールバックするので、herdr は必須ではない。

## 特徴

- **一体管理** — worktree・ブランチ・herdr workspace・エージェント起動を 1 コマンドに集約
- **欠落ファイルの補完** — `.worktreeinclude` に列挙した gitignore 済みファイルを実体コピー、本体の `.env` を symlink、`.claude/settings.local.json` をコピー。fresh checkout ではテストが動かない問題を解消する
- **作業の受け渡し** — `--prompt` / `--prompt-file` で worktree 側の Claude Code に初期プロンプトを渡す。`/wt` などの slash command skill を同梱
- **セッション間の会話** — worktree 側と dev 側の Claude Code セッションが直接やり取りできる。`wt new` が worktree 側のセッション名を `wt-<task>` に固定し、`wt peers` が宛先を一覧する
- **repo 固有の準備を委譲** — DB コピーや native rebuild などは repo 側の `scripts/worktree-setup` に委ねる契約
- **マージ前チェック** — repo 側の `scripts/check` をマージ前に worktree で実行し、失敗したら取り込まない。CI と同一のエントリポイントを共有する契約
- **graceful fallback** — herdr サーバに接続できなければ `git worktree` の作成だけで続行する

## 前提

| ツール | 要否 | 用途 |
| --- | --- | --- |
| bash 4+ | 必須 | 本体 |
| git | 必須 | worktree 操作 |
| [herdr](https://herdr.dev) | 任意 | workspace / エージェント起動（無ければ git worktree のみ）。socket API の `worktree` / `agent start` を使うため herdr 0.8（socket API protocol 19）で検証している |
| jq | herdr 使用時と `wt peers` で必須 | herdr の JSON 出力とセッションレジストリのパース |
| python3 | `/wt-review` で必須 | `skills/wt-review/assets/render.py` がレビューページを組み立てる（標準ライブラリのみ） |
| curl | レビューページで mermaid を使うとき | `mermaid.min.js` を一度だけ `~/.cache/wt/` に取得する |

## インストール

### plugin マーケットプレイス経由（Claude Code）

このリポジトリは Claude Code の plugin マーケットプレイスも兼ねており、`/plugin` で本体と skill がまとめて入る。

```
/plugin marketplace add kawase1295/wt
/plugin install wt@wt
```

plugin は `wt` を Bash tool の `PATH` に載せ、skill を plugin の名前空間に登録する。呼び出しは `/wt:wt`、`/wt:wt-review` のようにプレフィックスが付く。

更新の届き方は、マーケットプレイスの登録方法で変わる。

- **GitHub source**（`/plugin marketplace add kawase1295/wt`）— そのコミットが `~/.claude/plugins/cache/` にスナップショットされる。新しいコミットに移るには `/plugin marketplace update wt` を実行する。
- **ローカルディレクトリ source**（`/plugin marketplace add /path/to/wt`。開発中はこちらが便利）— plugin root がその checkout に解決されるため、CLI と skill は checkout に live で追従する。更新操作は要らない。新しいセッションはそこにコミットされている内容をそのまま読む。

知っておくことが 3 つある。

- **自分のシェルからは `wt` が見えない。** `PATH` に載るのは Claude Code の Bash tool の中だけ。ターミナルで `wt` を打ちたいなら下の手動配置も併せて行えるが、次の項目を先に読む。
- **手動配置は必ず plugin 版に勝つ。** plugin の `bin/` は Bash tool の `PATH` の**末尾**に足されるため、`install.sh` が置いた `~/.local/bin/wt` があればそちらが常に選ばれる。それが plugin 版より古いと、Claude Code は黙って古い CLI を使い続ける。気づくのは依存側のインターフェースが変わって `wt new` が壊れた日になる。手動配置を意識して同期し続けるか、plugin に寄せて手動配置を削除する。
- **`install.sh` の後片付けはしない。** `~/.claude/skills/` に既にある skill は plugin 側のコピーと並んで読み込まれ、同じものが 2 つ入る。どちらか一方に寄せる（`~/.claude/skills/` から wt の skill を消すか、plugin を入れない）。

### 手動配置

`wt` は単一ファイル。PATH の通ったディレクトリに置くだけで動く。

```bash
git clone https://github.com/kawase1295/wt.git
install -m 755 wt/wt ~/.local/bin/wt   # ~/.local/bin が PATH にある前提
```

同梱の `install.sh` は配置に加えて Claude Code skill（後述）も `~/.claude/skills/` に入れる。

```bash
./install.sh                     # ~/.local/bin/wt + ~/.claude/skills/ に配置
PREFIX=~/bin ./install.sh        # 本体の配置先を変える
WT_SKILLS_DIR=~/.claude/skills ./install.sh  # skill の配置先を変える
WT_INSTALL_SKILLS=0 ./install.sh # skill を配置しない
```

skill は wt の管理物として扱う。install のたびに skill ディレクトリを作り直すため、repo から消えたファイルは配置先にも残らない — ローカルの改変も残らない。改変している場合は `WT_INSTALL_SKILLS=0` で守る。

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

wt browse <path>
    ローカルファイルをそのプラットフォームの既定の手段で開く（WSL は explorer.exe、
    macOS は open、Linux は xdg-open）。skill が生成した HTML を開くのに使う。
    開く手段が無ければパスを表示して失敗する

wt list
    worktree と herdr workspace の対応を一覧表示

wt peers [--json]
    この repo の Claude Code セッション（本体 / 各 worktree）を一覧表示する。
    name 列がセッション間メッセージ（SendMessage）の宛先。(self) は自分。
    worktree 側は wt new が付ける固定名 wt-<task> になる

wt merge [<task>] [--no-check]
    ブランチ worktree-<task> を本体の現在ブランチへマージする。
    worktree 内から task 省略で自分を対象にできる。コンフリクトは本体に残して中断。
    worktree に scripts/check（実行可能ファイル）があればマージ前に実行し、
    失敗したらマージしない（--no-check で省略）

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

# dev ↔ worktree のセッションの宛先を確認する（会話の相手を探す）
wt peers

# worktree の中から: 成果を本体に取り込み、自分を片付ける
wt merge   # scripts/check があれば実行してから本体の現在ブランチへマージ
wt rm      # worktree / workspace / ブランチを削除して workspace を閉じる
```

worktree は Claude Code の native worktree と同じ `<repo>/.claude/worktrees/<task名>` に、ブランチ `worktree-<task名>` で作られる。native（`claude --worktree`）と同じ実体を指すので、native で作った worktree も `wt open` / `wt bootstrap` / `wt rm` で扱える。`WT_HOME` を設定すると従来の集約置き場 `$WT_HOME/<repo名>/<task名>` に作る。

## 仕組み

### bootstrap の分担

fresh な worktree は本体の gitignore 済みファイルを持たないため、テストやアプリが動かないことがある。`wt` はこれを 2 段で補完する。

**共通処理（`wt` 本体）**

1. `.worktreeinclude`（repo root、要コミット、gitignore 構文）に列挙された gitignore 済みファイルを本体から実体コピー（既存ファイルは上書きしない）
2. 本体の `.env` を worktree へ symlink（実体ファイルが既にあれば触らない。`.worktreeinclude` に `.env` があればコピーが先に走るので、そちらが優先される）
3. `.claude/settings.local.json` をコピー（Claude Code の許可設定の引き継ぎ）
4. repo フックがあれば委譲、無ければ `node_modules` が存在しないときに限り、lockfile から検出した package manager で依存インストール（npm / pnpm / yarn / bun / uv に対応）

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

### マージ前チェック（repo の `scripts/check`）

`wt merge` はマージの直前に worktree の `scripts/check`（実行可能ファイル、cwd = worktree）を実行し、非 0 で終わったらマージしない。テスト・型チェック・lint など「取り込み条件」をここに 1 本化する。

- `scripts/check` が無い repo では警告だけ出してマージを通す（段階導入できる）
- `--no-check` で省略できる
- check は working tree に対して走るため、未コミット変更も見える（未コミット変更はマージには含まれない。`wt merge` が警告を出す）
- CI（GitHub Actions 等）からも同じ `scripts/check` を叩くと、ローカルゲートと CI の検査内容が乖離しない。wt 自身の [.github/workflows/ci.yml](.github/workflows/ci.yml) と [scripts/check](scripts/check) が実例

```bash
#!/usr/bin/env bash
# scripts/check — 取り込み条件をまとめて検査する（例: TypeScript repo）
set -euo pipefail
npx tsc --noEmit
npm test
```

## Claude Code 連携

[`skills/`](skills/) に 8 つの skill を同梱しており、`install.sh` が `~/.claude/skills/` に配置する（[plugin](#plugin-マーケットプレイス経由claude-code) 経由なら plugin 側が供給し、名前は `/wt:wt-review` のようにプレフィックスが付く）。dev（本体 checkout）側のセッションから作業を worktree に投げ、worktree 側のセッションでレビュー・取り込み・片付けを完結させる。作業中は両者が直接会話できる。

skill は `SKILL.md` 1 枚に限らない。`/wt-review` はレビューページの HTML テンプレートと生成スクリプトを [`skills/wt-review/assets/`](skills/wt-review/assets/) に同梱している。`install.sh` が skill ディレクトリごとコピーするのはこのため。

| skill | 実行する側 | 役割 |
| --- | --- | --- |
| `/wt <作業内容>` | dev | worktree 名を生成し、作業内容を初期プロンプトとして worktree + Claude Code を起動 |
| `/wt-detail <作業内容>` | dev | コードベースを調査し、仕様の不明点をユーザーに確認してから実装プランを作り、初期プロンプトとして worktree に渡す |
| `/wt-review` | worktree | 同梱テンプレートに diff を `assets/render.py` で差し込んでレビュー用 HTML を作り、ブラウザで開いて承認を待つ |
| `/wt-merge` | worktree | 自分のブランチを本体の現在ブランチへマージ（`scripts/check` があればマージ前に実行。コンフリクトは報告して停止） |
| `/wt-clean` | worktree | 未コミット・未マージを検査し、クリーンなら自分の worktree を片付けて workspace を閉じる |
| `/wt-ask <内容>` | 両方 | `wt peers` で相手セッションの宛先を解決し、質問・報告を送って返答を受ける |
| `worktree-parallel` | 両方 | `wt` と native worktree の使い分け方針・`.worktreeinclude` の契約（[skills/worktree-parallel/SKILL.md](skills/worktree-parallel/SKILL.md)） |
| `local-artifact` | 両方 | Artifact と同一の設計規約で HTML を作り、claude.ai に publish せずローカル公開する契約。`/wt-review` はもうロードしない（skeleton・テーマトグル・mermaid をテンプレートが内包しているため） |

典型的なフロー:

```
dev 側:      /wt ログイン画面のバリデーション修正
              → worktree + workspace が開き、Claude が作業内容付きで起動する
worktree 側: (実装・コミット) → /wt-review → (ユーザーがレビュー・承認) → /wt-merge → /wt-clean
              → 本体に取り込まれ、worktree / workspace / ブランチが消えて閉じる
```

### セッション間の会話（dev ↔ worktree）

worktree 側と dev 側のセッションは、Claude Code のセッション間メッセージ（`ListAgents` / `SendMessage`）で直接会話できる。仕組み自体は Claude Code 側にあり（レジストリは `<config>/sessions/<pid>.json`、その `name` が宛先）、`wt` が担うのは**宛先の決定**だけ。

- `wt new` は `claude -n wt-<task>` で起動するので、**worktree 側の宛先名は `wt-<task>` に固定**される。dev 側は task 名だけで宛先を決められる
- dev 側の名前は Claude Code の自動命名（`<ディレクトリ名>-<2 文字>`）。`wt peers` の `role=dev` 行で引く
- `wt peers` はこの repo（本体 + 全 worktree）に属する**生存中の**セッションだけを role 付きで一覧する（死んだセッションのレジストリファイルは残るため）

```
$ wt peers
ROLE                 NAME                     KIND         STATUS   SELF   CWD
dev                  wt-92                    interactive  busy     (self) /home/you/projects/wt
fix-login            wt-fix-login             interactive  idle            /home/you/projects/wt/.claude/worktrees/fix-login
```

想定する使い方は「worktree 側が仕様の判断を dev 側に仰ぐ」「dev 側が方針変更や追加情報を伝える」。`/wt` と `/wt-detail` は初期プロンプトに「判断に迷ったら勝手に決めず dev 側に聞く」を含めるため、worktree 側は独断で進める代わりに聞いてくる。送受信の作法は `/wt-ask` に集約している。

古い Claude Code で起動されたセッションは peer レジストリに載らないため会話できない（`wt peers` にも `ListAgents` にも出てこない）。

## 既知の注意点

- worktree は `<repo>/.claude/worktrees/` に作られるため、本体 checkout の `git status` に `.claude/` が untracked として現れる（Claude Code の native worktree でも同じ）。無視設定が無いかぎり `wt new` が毎回案内する。本体の `.gitignore` か `.git/info/exclude` に `.claude/worktrees/` を加えれば案内は止まる。それまでは `git add .` で worktree の実体を巻き込まないよう注意。
- `~/.npmrc` に `ignore-scripts=true` があると、`npm ci` だけでは native addon（better-sqlite3 等）がビルドされない。フックで rebuild するか、本体のビルド済み `.node` をコピーする。
- 本体 checkout の未コミット変更は worktree に入らない（worktree はコミット済み ref から分岐する）。
- `.worktreeinclude` のコピーではディレクトリパターン（`secrets/`）がそのまま使える。フックで symlink する場合のみ末尾スラッシュ無し（`secrets`）で書く。
- `.worktreeinclude` の否定パターン `!` は、親ディレクトリごと除外した配下を再 include できない（gitignore の仕様）。`secrets/` + `!secrets/x` は効かず、`secrets/*` + `!secrets/x` と書く。
- 空ディレクトリと、エントリ自体が相対 symlink のファイルは正しく持ち込めない（git が列挙しない / リンク先が worktree 内で切れる）。
- `wt merge` のコンフリクトは本体 checkout の working tree に発生する。解決するか `git merge --abort` で戻すまで本体が merge 中の状態になる。

## 開発

```bash
scripts/check     # shellcheck + マニフェスト検査 + テスト。wt merge のゲートと CI が叩くのと同じ入口
tests/wt_test.sh  # 34 ケース。依存は git と coreutils のみ（bats 不要）
```

`scripts/check` は `claude` CLI があれば `claude plugin validate .` も走らせるので、`.claude-plugin/` のマニフェストが壊れた状態はマーケットプレイスに出る前に落ちる。`python3` があれば `skills/wt-review/assets/render.py` の構文検査も走らせる。生成スクリプトは標準ライブラリだけで書いてあるので linter は入れない。plugin エントリに `version` を意図的に持たせていない点に注意する。付けると値を上げるまでその版に固定され、`main` に push したコミットがユーザーへ届かなくなる。

テストは `herdr` を PATH から隠して git worktree フォールバック経路を強制し、herdr 経路自体の検証では fake herdr を差し込む。`HOME` は temp に差し替えるため実ホームを汚さない。

## ライセンス

[MIT](LICENSE)
