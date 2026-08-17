---
name: worktree-parallel
description: git worktree で並列開発セッションを作成・補完・削除する統一方針。wt コマンド (herdr 連携) と Claude Code ネイティブ worktree (--worktree / subagent isolation) の使い分け、`.worktreeinclude`（持ち込むファイル一覧の正）と repo フック scripts/worktree-setup の契約。worktree で .env / secrets / 依存が無くてテストやアプリが動かないときの補完にも使う。
---

# worktree 並列開発 (wt)

`wt` コマンドが、git worktree と herdr workspace を一体で管理する。対象リポジトリ内の任意の場所から実行する。

```bash
wt new <task> [--base <ref>] [--no-claude] [--prompt <text>|--prompt-file <path>]
                                             # worktree + workspace + Claude Code 起動
wt bootstrap [<path>]                        # 既存 worktree に欠落ファイルを補完
wt open <task>                               # 既存 worktree を workspace として開き直す
wt list                                      # worktree ↔ workspace の対応一覧
wt peers [--json]                            # この repo の Claude Code セッション一覧 (会話の宛先)
wt merge [<task>]                            # worktree ブランチを本体の現在ブランチへマージ
wt rm [<task>] [--force]                     # worktree / workspace / ブランチを削除
```

- worktree は native と同じ `<repo>/.claude/worktrees/<task名>` に、ブランチ `worktree-<task名>` で作られる (`WT_HOME` を設定すると従来の集約置き場 `$WT_HOME/<repo名>/<task名>`)。
- `--base` 省略時は本体 checkout の現在ブランチから分岐する。
- `--prompt` / `--prompt-file` は worktree 側で起動する Claude Code への初期プロンプト。herdr サーバが無いとプロンプトを渡せないため die する。
- worktree 側の claude は既定で `-n wt-<task> --model opus --permission-mode auto` 付きで起動する（`WT_CLAUDE_ARGS` で差し替え、空文字でフラグ無し。`-n` は常に付き、`WT_CLAUDE_ARGS` 側の `-n` が後勝ちで上書きする）。
- `merge` / `rm` は worktree 内から task 省略で実行でき、自分の worktree を対象にする（worktree 側セッションの `/wt-merge` `/wt-clean` が使う）。
- herdr サーバが起動していなければ git worktree の作成だけにフォールバックする。

## native worktree との使い分け（統一方針）

Claude Code 自身も worktree を作る（`claude --worktree`、subagent の `isolation: worktree`、desktop の並列セッション）。`wt` と native は**同じ置き場・同じブランチ命名**（`<repo>/.claude/worktrees/<name>/`、ブランチ `worktree-<name>`）を共有し、同じ worktree を指す。違うのは作り方と補完方法で、native は fresh コピー中心・base 既定 `origin/HEAD`、`wt` は herdr workspace 起動と symlink 補完込み・base 既定は本体の現在ブランチ。同じ実体なので native で作った worktree を `wt open` / `wt bootstrap` / `wt rm` でそのまま扱える。単一の補完 hook が両方をまたげないため、**`.worktreeinclude` を「持ち込むファイル一覧の唯一の正」**として両方で共有する。

- **`.worktreeinclude`**（repo root、**要コミット**）: fresh checkout に要る gitignore 済みファイルを `.gitignore` 構文で列挙。native はこれを読んで**自動でコピー**し、`wt bootstrap` もこれを読んで本体から**実体コピー**する（既存ファイルは上書きしない）。フックが worktreeinclude を読む必要はない。
- **`scripts/worktree-setup`**（repo フック、**要コミット**）: コピーで表せない補完＝依存インストール・環境 symlink 再生成・native rebuild。`wt` はこれに委譲する。**native はこのフックを呼ばない**ので、依存が要る repo の native worktree は作成後に `wt bootstrap <path>` で仕上げる。
- base の既定が違う（native=`origin/HEAD` fresh / `wt`=本体の現在ブランチ）。揃えたいときは settings に `"worktree": { "baseRef": "head" }`。
- `.worktreeinclude` / フックは**コミット必須**。native の fresh base は未コミットファイルを見ない。

使い分け: 軽量・使い捨て・subagent 分離は native（`claude --worktree`）、herdr workspace 起動や欠落補完込みで立ち上げたいときは `wt`。同じ場所を指すので、native で作ったものを後から `wt open` / `wt bootstrap` で仕上げてもよい。

## bootstrap の分担

共通処理 (wt 本体):

1. `.worktreeinclude` に列挙されたファイルを本体から実体コピー (既存ファイルは上書きしない)
2. 本体の `.env` を worktree へ symlink (実体ファイルが既にあれば触らない。`.worktreeinclude` に `.env` があればコピーが優先される)
3. `.claude/settings.local.json` をコピー (Claude Code の許可設定の引き継ぎ)
4. repo フックがあれば委譲、無ければ lockfile から検出した package manager で依存インストール

repo 固有処理 (repo の `scripts/worktree-setup`、実行可能ファイル):

- cwd = worktree で呼ばれ、`WT_MAIN_ROOT` (本体 checkout) と `WT_TARGET` (worktree) が渡される
- 依存インストールを**含めて**フック側の責任 (フックがあると wt は install しない)
- 推奨実装: 環境 symlink の再生成 → 依存インストール → native rebuild。worktreeinclude の補完は wt 本体が済ませているのでフックで読む必要はない。`WT_SKIP_DEPS=1` で config 補完だけ回せると再補完が速い
- 典型的な内容: gitignore された secrets/credentials の symlink 共有、ローカル DB のコピー独立、native addon の補完
- monorepo での参照実装イメージ: gitignore された config の symlink・環境固有ファイルの symlink 再生成・各パッケージ (`client` / `infra` 等) の `npm ci`・Python パッケージの `uv sync` を 1 つのフックにまとめる

## セッション間の会話 (dev ↔ worktree)

worktree 側セッションと dev 側セッションは、Claude Code のセッション間メッセージ (`ListAgents` / `SendMessage`) で直接会話できる。仕組みは Claude Code 側にあり (レジストリは `<config>/sessions/<pid>.json`、`name` が宛先)、wt が担うのは**宛先の決定**だけ。

- `wt new` は `claude -n wt-<task>` で起動するので、**worktree 側セッションの宛先名は `wt-<task>` に固定**される。dev 側は task 名から宛先を決められる。
- dev 側セッションの名前は Claude Code の自動命名（`<ディレクトリ名>-<2 文字>`）。`wt peers` の `role=dev` 行で引く。
- `wt peers` はこの repo（本体 + 全 worktree）に属する**生存中の**セッションを role (`dev` / task 名) 付きで一覧する。死んだセッションのレジストリファイルは残るので生存を確認し、cwd が worktree のサブディレクトリでも正しく分類する。`--json` で機械可読。
- 送受信の作法（宛先解決、初回の `[ref]` 再送、返信は `from` を使う、権限の回し合いをしない）は skill `/wt-ask` に集約する。

peer レジストリに載らないセッション（古い Claude Code で起動したもの、既に終了したもの）とは会話できない。`wt peers` にも `ListAgents` にも出てこなければ宛先にできないので、レビューページやコミットメッセージ経由の受け渡しに切り替える。

## 既知の注意点

- `~/.npmrc` に `ignore-scripts=true` があると、`npm ci` だけでは native addon (better-sqlite3 等) がビルドされない。フックで `npm rebuild <pkg> --ignore-scripts=false --foreground-scripts` するか、本体のビルド済み `.node` をコピーする。
- Claude Code が自分で作る worktree (`.claude/worktrees/*`) も同じ欠落を持つ。テストや実行が必要なら `wt bootstrap <path>` で補完する。
- 本体 checkout の未コミット変更は worktree に入らない (worktree はコミット済み ref から分岐する)。
- `.worktreeinclude` のコピー (wt / native) ではディレクトリパターン `secrets/` がそのまま使える。フックで symlink する場合のみ末尾スラッシュ無し (`secrets`) で書く。
- `.worktreeinclude` の否定パターン `!` は、親ディレクトリごと除外した配下を再 include できない (gitignore の仕様)。`secrets/` + `!secrets/x` は効かず、`secrets/*` + `!secrets/x` と書く。
- 空ディレクトリはコピーされない (git が列挙しないため)。

## slash command skill

wt repo は 6 つのコマンド skill を同梱し、install.sh が `~/.claude/skills/` に配置する。

| skill | 実行する側 | 役割 |
| --- | --- | --- |
| `/wt <作業内容>` | dev (本体) | worktree 名を生成し、初期プロンプト付きで worktree + Claude を起動 |
| `/wt-detail <作業内容>` | dev (本体) | コード調査 → 不明点をユーザーに確認 → 実装プランを初期プロンプトとして worktree に渡す |
| `/wt-ask <内容>` | 両方 | `wt peers` で宛先を解決し、相手セッションに質問・報告を送る |
| `/wt-review` | worktree | 変更の diff からレビュー用 HTML を生成してブラウザで開き、マージ承認を待つ |
| `/wt-merge` | worktree | 自分のブランチを本体の現在ブランチへマージ（レビュー指示があれば承認後） |
| `/wt-clean` | worktree | 未コミット・未マージを検査し、クリーンなら自分の worktree を片付けて閉じる |

このほか契約 skill `local-artifact` を同梱する。Artifact と同一の設計規約で HTML を作り、claude.ai に publish せずローカル公開する（skeleton / テーマトグル / mermaid の再現込み）。`/wt-review` のレビューページ生成はこれに従う。
