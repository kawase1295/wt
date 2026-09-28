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
- **レビューページから承認** — `/wt-review` がページを `127.0.0.1` の使い捨て HTTP サーバで配信するので、「承認してマージ」ボタンの押下がそのまま worktree セッションへの**ユーザー入力**として届く。ターミナルに戻る必要がない。herdr や python3 が無ければ `file://` 表示（ボタン無し）に落ちる
- **GitHub issue / PR 連携（skill）** — `/wt` が issue を起票して worktree 名と初期プロンプトに紐付け、`/wt-merge` が `Fixes #N` 付きの PR を作成し、`/wt-review` の承認を通っていれば CI の完了を待ってマージまで実行する。タスク = issue = ブランチ = PR が 1:1 で対応する。remote の無い repo では従来のローカルマージ
- **本体 checkout のガード（hook）** — 本体 checkout でブランチを切って直接作業しようとすると `PreToolUse` hook が理由付きで deny し、worktree 経由（`wt open` / `wt new`）へ誘導する。worktree を経由しない作業を、skill の文章ではなく Bash の実行前検査で止める（plugin 経由のみ）
- **graceful fallback** — herdr サーバに接続できなければ `git worktree` の作成だけで続行する

## 前提

| ツール | 要否 | 用途 |
| --- | --- | --- |
| bash 4+ | 必須 | 本体 |
| git | 必須 | worktree 操作 |
| [herdr](https://herdr.dev) | 任意 | workspace / エージェント起動（無ければ git worktree のみ）。socket API の `worktree` / `agent start` を使うため herdr 0.9（socket API protocol 22）で検証している |
| jq | herdr 使用時と `wt peers` で必須 | herdr の JSON 出力とセッションレジストリのパース |
| python3 | `/wt-review` で必須 | `skills/wt-review/assets/render.py` がレビューページを組み立て、`wt-review-serve.py` が配信して承認ボタンを herdr へのプロンプト投入に変換する（標準ライブラリのみ） |
| curl | レビューページで mermaid を使うとき | `mermaid.min.js` を一度だけ `~/.cache/wt/` に取得する |
| [gh](https://cli.github.com/) | 任意 | GitHub issue / PR 連携（`/wt` の issue 起票、`/wt-merge` の PR 作成、`/wt-clean` の PR 検査）。無ければ従来のローカルフロー |

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

`wt` は単一ファイル。PATH の通ったディレクトリに置くだけで動く。レビューページの使い捨て配信サーバ（`wt serve` が起動する `wt-review-serve.py`）は `wt` の隣に置く。

```bash
git clone https://github.com/kawase1295/wt.git
install -m 755 wt/wt ~/.local/bin/wt   # ~/.local/bin が PATH にある前提
install -m 755 wt/wt-review-serve.py ~/.local/bin/wt-review-serve.py
```

`wt` は配信サーバを自分の隣から探す。置かなければ `wt serve` が起動を諦めるだけで、失うのは承認ボタンだけ（`/wt-review` は `file://` 表示に落ちる）。

同梱の `install.sh` は配置に加えて Claude Code skill（後述）も `~/.claude/skills/` に入れる。

```bash
./install.sh                     # ~/.local/bin/wt + ~/.claude/skills/ に配置
PREFIX=~/bin ./install.sh        # 本体の配置先を変える
WT_SKILLS_DIR=~/.claude/skills ./install.sh  # skill の配置先を変える
WT_INSTALL_SKILLS=0 ./install.sh # skill を配置しない
```

skill は wt の管理物として扱う。install のたびに skill ディレクトリを作り直すため、repo から消えたファイルは配置先にも残らない — ローカルの改変も残らない。改変している場合は `WT_INSTALL_SKILLS=0` で守る。

[ブランチ切替のガード](#本体-checkout-のガードhook)は plugin の機構でのみ読み込まれる。`install.sh` が配るのは skill までなので、手動配置では hook は有効にならない。

## 使い方

対象リポジトリ内の任意の場所から実行する。

```bash
wt new <task> [--base <ref>] [--no-claude] [--prompt <text>|--prompt-file <path>]
    worktree を <repo>/.claude/worktrees/<task>（ブランチ worktree-<task>）に作り、
    herdr workspace を開き、bootstrap 後に Claude Code を起動する
    （base 省略時は本体の現在ブランチ）。
    --prompt / --prompt-file は起動する Claude への初期プロンプト（要 herdr）。
    プロンプトは起動 argv ではなく起動後の herdr agent prompt で投入するので、
    改行入りの長文もそのまま 1 ターンとして届く。
    本文の先頭（空白・改行を除く）が / ! # @ なら Claude Code が
    slash command / bash / memory / file mention として解釈するため拒否する。
    claude には既定で --model opus --permission-mode auto を渡す
    （WT_CLAUDE_ARGS で差し替え、空文字でフラグ無し。空白を含む値は不可）。
    Claude Code の起動・プロンプト投入に失敗しても worktree / workspace は残し、
    herdr の error.code ごとの次の手と wt open <task> / wt rm <task> を案内する:
      agent_not_ready         pane で信頼ダイアログを承認し、案内の
                              herdr agent prompt claude-<task> … で再投入する
      invalid_agent_argument  WT_CLAUDE_ARGS を見直す（渡した引数を表示）
      それ以外・code なし     herdr の出力をそのまま表示
    初期プロンプトは worktree の git ディレクトリに wt-initial-prompt.txt として
    退避し、再投入コマンドはそこから読む。呼び出し元が --prompt-file を消しても
    使える（wt rm で一緒に消える）。このファイルは「初期プロンプト未投入」の目印を
    兼ね（issue-board と共有）、再投入コマンドは投入に成功したときだけ消す

wt bootstrap [<path>]
    既存 worktree に、gitignore されて入らないファイルを補完する。
    Claude Code が作る .claude/worktrees/* にも使える

wt open <task>
    既存 worktree を herdr workspace として開き直す

wt browse <path|url>
    ローカルファイルをそのプラットフォームの既定の手段で開く（WSL は explorer.exe、
    macOS は open、Linux は xdg-open）。http(s) の URL も渡せる（wt serve の出力）。
    WSL では URL だけ rundll32 の FileProtocolHandler に渡す
    （explorer.exe は URL を開けない）。skill が生成した HTML を開くのに使う。
    開く手段が無ければパスを表示して失敗する

wt serve <path> [--task <task>] / wt serve --stop [--task <task>]
    レビューページを 127.0.0.1 の空きポートに立てた使い捨て HTTP サーバで配信し、
    ?token=... 付きの URL を stdout に 1 行出す。ページの承認ボタンの POST を
    herdr agent prompt claude-<task> に変換し、承認を worktree セッションへ
    ユーザーの直接入力として届けて終了する。HTML はリクエストごとに読み直すので、
    再レビューはブラウザのリロードだけで最新化される。worktree 内なら --task 省略で
    ブランチから推定する。herdr が使えなければ起動せず失敗し、
    呼び出し側（/wt-review）は file:// で開く従来手順に落ちる

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

wt loop [<issue>...] [--label <name>] [--max-issues <n>] [--max-rounds <n>] [--dry-run]
wt loop --stop / wt loop status
wt loop doctor [--label <name>] [--fix-labels]
    ラベル付き（既定 wt-loop）の open issue を、人間の操作なしに
    worktree 作成 → headless claude で実装 → scripts/check → 別セッションの AI レビュー
    → PR → CI → マージ → 片付け → 次の issue、と回す driver。落ちた工程は同じ worker に
    渡して再試行（上限 --max-rounds）、超えたら needs-human ラベルで切り出して次へ進む。
    wt loop doctor は repo がループに乗せられる状態かを診断する（wt loop も起動前に
    同じ検査を走らせ、NG なら始めない）。詳細は「無人ループ」の節
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

[`skills/`](skills/) に 11 の skill を同梱しており、`install.sh` が `~/.claude/skills/` に配置する（[plugin](#plugin-マーケットプレイス経由claude-code) 経由なら plugin 側が供給し、名前は `/wt:wt-review` のようにプレフィックスが付く）。dev（本体 checkout）側のセッションから作業を worktree に投げ、worktree 側のセッションでレビュー・取り込み・片付けを完結させる。作業中は両者が直接会話できる。

skill は `SKILL.md` 1 枚に限らない。`/wt-review` はレビューページの HTML テンプレートと生成スクリプトを [`skills/wt-review/assets/`](skills/wt-review/assets/) に同梱している。`install.sh` が skill ディレクトリごとコピーするのはこのため。

| skill | 実行する側 | 役割 |
| --- | --- | --- |
| `/wt <作業内容>` | dev | worktree 名を生成し、作業内容を初期プロンプトとして worktree + Claude Code を起動。GitHub リポジトリでは先に issue を起票（`/wt #123` で既存 issue も可）し、番号を名前とプロンプトに紐付ける |
| `/wt-detail <作業内容>` | dev | コードベースを調査し、仕様の不明点をユーザーに確認してから実装プランを作り、初期プロンプトとして worktree に渡す。GitHub リポジトリではプラン確定後に issue を起票し、プラン全文を issue に残す |
| `/wt-split <親issue>` | dev | 複数タスクを含む親 issue を子 issue に分解して起票し、独立な子ごとに worktree + Claude Code を並列起動。依存のある子は先行の子が閉じたあと再実行で追加起動する |
| `/wt-review` | worktree | 同梱テンプレートに diff を `assets/render.py` で差し込んでレビュー用 HTML を作り、`wt serve`（承認ボタン付き）か `file://` で配信してブラウザで開き、承認を待つ |
| `/wt-auto-review` | worktree | /wt-split の子タスク専用の AI レビュー。新規 subagent に diff と受け入れ条件だけを渡して評価させ、PASS で /wt-merge の承認ゲートを満たしてマージまで自動で進める。2 巡で通らなければ /wt-review の人間レビューにフォールバック |
| `/wt-merge` | worktree | GitHub リポジトリでは `scripts/check` → push → `Fixes #N` 付きの PR を作成 → 承認ゲートを通っていれば CI の完了を待って `gh pr merge --merge` → remote ブランチを削除（未通過なら PR 作成で停止）。remote が無ければ本体の現在ブランチへローカルマージ（コンフリクトは報告して停止） |
| `/wt-clean` | worktree | 未コミットと取り込み状態（PR の MERGED / 本体への未マージ）を検査し、クリーンなら自分の worktree を片付けて workspace を閉じる |
| `/wt-ask <内容>` | 両方 | `wt peers` で相手セッションの宛先を解決し、質問・報告を送って返答を受ける |
| `/wt-loop` | dev | ラベル付き issue を `wt loop` で人間の操作なしにマージまで回す。起動（`--dry-run` で対象を見せてから background 起動）・監視・停止（[無人ループ](#無人ループwt-loop)） |
| `worktree-parallel` | 両方 | `wt` と native worktree の使い分け方針・`.worktreeinclude` の契約（[skills/worktree-parallel/SKILL.md](skills/worktree-parallel/SKILL.md)） |
| `local-artifact` | 両方 | Artifact と同一の設計規約で HTML を作り、claude.ai に publish せずローカル公開する契約。`/wt-review` はもうロードしない（skeleton・テーマトグル・mermaid をテンプレートが内包しているため） |

典型的なフロー（GitHub リポジトリ）:

```
dev 側:      /wt ログイン画面のバリデーション修正
              → issue #42 を起票し、worktree + workspace が開き、Claude が issue 本文付きで起動する
worktree 側: (実装・コミット) → /wt-review → (ユーザーがレビュー・承認) → /wt-merge
              → PR 作成（Fixes #42）→ CI (scripts/check) の完了を待つ → gh pr merge
              → /wt-clean → worktree / workspace / ブランチが消えて閉じる
```

タスク = issue = ブランチ（`worktree-42-fix-login-validation`）= PR が 1:1 で対応し、PR のマージで issue が自動で閉じる。マージ判断の実体は `/wt-review` の承認ゲートなので、通過したセッションはマージまで自分で実行する（未通過なら PR 作成で止まり、ユーザーの判断を待つ）。GitHub remote が無い repo（または gh が無い環境）では issue / PR の手順が抜け、`/wt-merge` は本体の現在ブランチへのローカルマージになる:

```
worktree 側: (実装・コミット) → /wt-review → (ユーザーがレビュー・承認) → /wt-merge → /wt-clean
              → 本体に取り込まれ、worktree / workspace / ブランチが消えて閉じる
```

### 無人ループ（wt loop）

上のフローは、レビューの承認・マージ判断・次の issue への移行を人間が担う。`wt loop` はそこを bash の driver（[`wt-loop`](wt-loop)）に置き換え、ラベル付きの issue を人間の操作なしにマージまで回す。

```
wt loop（dev 側、bash）
  issue 選択 → worktree 作成（origin/<default> から）
  → worker:   claude -p（実装・コミット。push はできない）
  → 未コミット無し? → origin/<default> 取り込み → scripts/check
  → reviewer: claude -p（diff + issue 本文 + 合否基準 → PASS / FAIL）
  → push → PR（Fixes #N）→ CI 待ち → gh pr merge → remote ブランチ削除 → 本体 pull → wt rm
  → 次の issue
```

Claude が担うのは「実装」と「レビュー判定」だけで、どちらも headless（`claude -p`）の別セッション。reviewer には diff と issue 本文と合否基準しか渡さない（書いた本人に合否を判定させない）。minor のみ PASS、blocker / major は FAIL、迷ったら FAIL。

落ちた工程（未コミット / コンフリクト / `scripts/check` / レビュー FAIL / CI）は、その内容を同じ worker セッションに `--resume` で渡して次のラウンドにする。ラウンド上限（`--max-rounds`、既定 3）を超える、worker が最終報告を `BLOCKED:` で始める（本番環境が要る・人間の判断が要る等）、push / merge が拒否される、CI 待ちが上限（`WT_LOOP_CI_TIMEOUT`、既定 1800 秒）に達する、のどれかで issue に `needs-human` ラベルとコメント（理由・worktree・state の場所）を付けて次の issue へ進む。worktree は残るので、原因を直してラベルを外し、`wt loop <N>` と番号で指定すれば、残った worktree と session を再利用して続きから進む。worker の問いには issue コメントで答えれば worker に届く（エスカレーション後に付いたコメントと、書き直した issue 本文を、driver が再開時のプロンプトに「前回からの引き継ぎ」として渡す。driver 自身のコメントと、前回の再開で渡したコメントは除く）。worker が起動直後（`WT_LOOP_INFRA_SECS`、既定 60 秒未満）に異常終了したときは作業の失敗ではなく利用上限や API 障害とみなし、その issue を `failed` にして loop 全体を止める（キュー全体に `needs-human` を付けない）。

**権限設定は変えない。** worker は `--permission-mode acceptEdits` と allowlist（git / テスト / パッケージマネージャ / 読み取り系のシェルコマンド。任意コードを実行できる `bash` / `sh` と `gh` は入れない。`WT_LOOP_EXTRA_TOOLS` で追記、`WT_LOOP_ALLOWED_TOOLS` で差し替え）で動く。headless では `--permission-mode auto` が書き込みを拒否するため使わない。

**worker は push できない。** これは permission ルール（`git -C` や `bash -c` で回避できる）ではなく、worker プロセスだけに効く環境で保証する: git の `url.<無効なパス>.pushInsteadOf` を環境変数（`GIT_CONFIG_*`）で与え、remote 名・`-C`・URL 直指定のどれで push しても存在しないパスへ書き換えて失敗させる（fetch / pull は通る）。環境変数の塞ぎは `git -c` や `GIT_CONFIG_COUNT` の上書きで外せるので、worker の PATH 先頭に置いた `git` の shim（`push` / `send-pack`、および `-c alias.*` / `remote.*.pushurl` / `url.*` / `credential.*` / `core.hooksPath` の上書きを拒否し、それ以外は実 git に委譲）でコマンド経路でも止める。あわせて `GH_CONFIG_DIR` を空ディレクトリにして gh を無認証にする（`gh pr merge` 等が失敗する）。worker が書いたコードを driver が実行する経路も同じ扱いにする: `scripts/check` は同じ sandbox 環境で走らせ、driver 自身の git 操作（merge / push / pull）は `core.hooksPath=/dev/null` で worktree の hook を無効にし、worker の実行前後で共有の `.git/config` に差分があれば（`pushurl` や `hooksPath` の設定など）進めずに `needs-human` に返す。

防いでいるのは「気を利かせて push してしまう」誤操作までで、`Bash(git *)` を許す以上、実 git を絶対パスで呼ぶ・環境を組み直す・`git -c alias.x='!…'` で任意のシェルを実行するといった意図的な回避は防げない。悪意のある worker を想定する場合は、この driver ではなくネットワークや認証の外側で塞ぐ必要がある。push / PR / merge は driver が自分の環境の git / gh で行う。

repo をループに乗せる前に `wt loop doctor` を実行する。本体 checkout で次を検査し、項目ごとに `OK` / `WARN` / `NG` と直し方を 1 行で出す: `scripts/check` が実行可能 / `.github/workflows/ci.yml` がある / `.claude/worktrees/` が ignore 済み / `gh` が認証済みで default branch を取得できる / ラベル `wt-loop`（`--label` で変更）と `needs-human` がある / 本体に未コミットの変更が無い（追跡ファイルが対象）/ `claude` CLI がある。NG が 1 つでもあれば exit 1。本体が default branch 以外にいるのは `WARN`（exit code に影響しない）: worktree は `origin/<default>` から切るので base は変わらず、マージ後の本体 pull がスキップされるだけ（plugin 配布のために main を checkout している repo など）。`wt loop` は起動前に同じ検査を走らせ、NG なら始めない。`--dry-run` は診断を出したうえで対象の一覧まで見せる（NG があれば exit 1）。`wt loop doctor --fix-labels` は無いラベルだけを作る（他の項目は直さず、repo のファイルにも触らない）。

対象の選び方:

- 引数に番号を並べればそれ、無ければラベル `wt-loop`（`--label` で変更。無ければ `wt loop doctor --fix-labels` で作る）付きの open issue
- `needs-human` ラベル付き、CLOSED、依存が未完了のものは飛ばす。ブランチ `worktree-<N>-*` が既にある issue は、ラベル選択では進行中として飛ばし、番号指定なら残っている worktree と session を再利用して再開する
- 本文に `## 子タスク` のチェックリストを持つ親 issue は子に展開し、「（#M のあと）」の依存が CLOSED の子だけを対象にする（`/wt-split` の表記と同じ）。子を単体で指定・ラベル付けした場合も、本文の「親 issue: #P」から親を引いて同じ依存判定をする。親自体は閉じない
- 直列で 1 issue ずつ。1 巡して何かマージできたら選び直し、依存が解けた子を同じ run で拾う。番号指定でも同じで、`wt loop <親>` は同じ番号から選び直して子を依存順にすべて回す（この run でマージ済みと CLOSED は除外されるので、単体の番号だけなら 1 巡で終わる）。`--max-issues` で件数を区切れる。`wt loop --stop` は次の区切り（claude 呼び出しの直後 / push の前 / issue の間）で止める
- 同じ repo で 2 本目の `wt loop` は起動できない（lock）

state は `~/.cache/wt/loop/<repo>-<key>/<N>/`（`WT_LOOP_STATE` で変更）に残る: ラウンドごとの worker のプロンプトと出力、reviewer の JSON、`scripts/check` のログ、diff、session id、PR URL。進行は同じ場所の `loop.log` に追記される。`wt loop status` で issue ごとの状態（`running` / `merged` / `needs-human` / `stopped` / `failed`）と、`events.jsonl` の最新 5 件を一覧できる。

前提: `gh`（認証済み）、`jq`、`claude`。「no checks reported」は、`.github/workflows` がある repo では check の登録待ちとみなして上限まで待ち、無い repo だけ一度待って再確認してから CI 無しと判断する（ローカルの `scripts/check` を根拠にマージ）。`scripts/check` も無い repo はゲート無しになるので、乗せる前に用意する（[マージ前チェック](#マージ前チェックrepo-の-scriptscheck)）。

#### イベント（events.jsonl）と通知（WT_LOOP_NOTIFY）

loop を別のセッションやスクリプトから監視するために、`~/.cache/wt/loop/<repo>-<key>/events.jsonl` に 1 イベント 1 行の JSON を追記する（`loop.log` を正規表現で追う必要はない）。

```json
{"at":"2026-09-28T01:23:45Z","event":"merged","repo":"owner/repo","issue":10,"round":1,"stage":null,"reason":null,"pr":"https://github.com/owner/repo/pull/12","message":"#10 Add greeting をマージした (https://github.com/owner/repo/pull/12)","state":"/home/me/.cache/wt/loop/repo-123"}
```

| フィールド | 内容 |
| --- | --- |
| `at` | UTC の ISO 8601（`YYYY-MM-DDThh:mm:ssZ`） |
| `event` | `run_started` / `issue_started` / `round` / `stage` / `merged` / `needs_human` / `failed` / `stopped` / `run_finished` |
| `repo` | `owner/repo` |
| `issue` | issue 番号。run 全体のイベント（`run_started` / `run_finished`、issue の間での `stopped`）では `null` |
| `round` | ラウンド番号（ラウンド開始前は `null`） |
| `stage` | `stage` イベントのみ: `worker` / `check` / `reviewer` / `pr` / `ci` / `merge` |
| `reason` | `needs_human` / `failed` / `stopped` の理由（1 行） |
| `pr` | PR の URL（作成後） |
| `message` | 人間向けの 1 行の要約（日本語） |
| `state` | state ディレクトリのパス |

値の無いフィールドは `null`（キーは常に全部そろう）。die などで異常終了したときも `run_finished` を出す。

環境変数 `WT_LOOP_NOTIFY` にコマンドを設定すると、`merged` / `needs_human` / `failed` / `run_finished` のイベントで、その JSON を stdin に渡して実行する（`sh -c` で解釈するので引数も書ける）。background で走らせ、10 秒で打ち切る。失敗しても loop は止めず、`loop.log` に 1 行出すだけ。コマンドの出力は state の `notify.log` に残る。`{"message": ...}` を読む既存の通知スクリプトをそのまま指定できる。

```bash
WT_LOOP_NOTIFY="$HOME/.claude/hooks/notify.sh" wt loop
# 最新のイベントを追う
tail -f ~/.cache/wt/loop/<repo>-<key>/events.jsonl | jq -r .message
```

### 本体 checkout のガード（hook）

wt の運用は「タスク = issue = ブランチ = PR」を worktree に 1:1 で対応させる。本体 checkout でブランチを切って直接作業してしまうと、この対応も `/wt-review` のレビューゲートも通らない。skill の文章は skill が起動して初めて読まれるので、起動しない経路（「issue を確認して」からそのまま実装に流れる等）には効かない。

そこで plugin は `PreToolUse` hook（[`hooks/main-checkout-guard.sh`](hooks/main-checkout-guard.sh)）を同梱し、Bash の実行前に検査する。**本体 checkout での**ブランチ切替を見つけたら理由付きの `deny` を返す。理由は Claude にそのまま渡り、場面別の代替手段（`worktree-*` ブランチ → `wt open <task>`、新規ブランチ作成 → `wt new <task>`、`gh pr checkout` → `gh pr view` / `gh pr diff` か worktree 内で実行）を読んで自分で進路修正できる。切替とみなすのは次のもの。

- `git checkout -b` / `git switch -c` / `--orphan` など、ブランチを作ってそこに移る操作
- 既存ブランチへの `checkout`（ローカルに無くても remote に同名があれば git が追跡ブランチを作って切り替えるので、それも含む）
- `gh pr checkout`。`git checkout` と同じように本体のブランチを動かす。PR を読む流れは worktree を経由しない作業に滑り込みやすいので、同じ扱いにしている

`ask` ではなく `deny` にしている。ask の確認でユーザーが No を選んでも Claude には理由のない拒否しか渡らず、そこでターンが止まる。deny の reason は Claude に自動で返るので、セッションを止めずに worktree 経由へ誘導できる。本体のブランチを動かす正当な用途（dev / main の行き来、rebase）は許可ブランチで素通しし、それ以外はユーザーの明示指示のもとで `WT_GUARD_DISABLE=1` を前置して通す（reason にもその旨を含める）。

素通しする経路:

- linked worktree の中（worktree 側は自分のブランチを自由に操作してよい）
- 切替先が許可ブランチ — `origin/HEAD` の指す default branch と `main` / `master` / `dev`
- `git checkout -- <path>` などのファイル復元、ブランチでない対象への `checkout`
- `pr checkout` 以外の `gh` サブコマンド（`gh pr view`、`gh pr diff` など）
- git work tree でない場所、JSON を読む手段（`jq` / `python3`）が無い環境

最後の 1 つのとおり、判定できない入力では素通しする。hook の不調がそのまま Bash 全体の停止になるのを避けるため、ガードは fail-open にしている。

| 環境変数 | 効果 |
| --- | --- |
| `WT_GUARD_DISABLE=1` | hook を無効化する |
| `WT_GUARD_ALLOW_BRANCHES` | 許可ブランチをカンマ区切りで差し替える（default branch は常に許可）。空文字なら default branch だけ |

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
- `wt serve` の listener は `127.0.0.1` にしか bind しない。WSL2 から Windows 側のブラウザで開けるのは localhost 転送が有効なとき（既定は有効）。届かない環境ではページが開けないので、`/wt-review` に `file://` で開かせる（`wt serve` を使わない）。
- 配信サーバは承認で終了するが、承認せずに閉じた場合は残る。`wt rm`（/wt-clean）が止めるほか、`wt serve --stop` で個別に止められる。放置しても 24 時間で自分を畳む。

## 開発

```bash
scripts/check     # shellcheck + マニフェスト検査 + テスト。wt merge のゲートと CI が叩くのと同じ入口
tests/wt_test.sh  # 34 ケース。依存は git と coreutils のみ（bats 不要）
tests/loop_test.sh # wt loop。claude と gh を stub に差し替え、bare の origin で push / merge / pull を実検証（要 jq）
```

`scripts/check` は `claude` CLI があれば `claude plugin validate .` も走らせるので、`.claude-plugin/` のマニフェストが壊れた状態はマーケットプレイスに出る前に落ちる。`python3` があれば同梱 python（`skills/wt-review/assets/render.py` と `wt-review-serve.py`）の構文検査も走らせる。どちらも標準ライブラリだけで書いてあるので linter は入れない。plugin エントリに `version` を意図的に持たせていない点に注意する。付けると値を上げるまでその版に固定され、`main` に push したコミットがユーザーへ届かなくなる。

テストは `herdr` を PATH から隠して git worktree フォールバック経路を強制し、herdr 経路自体の検証では fake herdr を差し込む。`HOME` は temp に差し替えるため実ホームを汚さない。

## ライセンス

[MIT](LICENSE)
