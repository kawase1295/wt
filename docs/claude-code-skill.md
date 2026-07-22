---
name: worktree-parallel
description: git worktree で並列開発セッションを作成・補完・削除する統一方針。wt コマンド (herdr 連携) と Claude Code ネイティブ worktree (--worktree / subagent isolation) の使い分け、`.worktreeinclude`（持ち込むファイル一覧の正）と repo フック scripts/worktree-setup の契約。worktree で .env / secrets / 依存が無くてテストやアプリが動かないときの補完にも使う。
---

# worktree 並列開発 (wt)

`wt` コマンドが、git worktree と herdr workspace を一体で管理する。対象リポジトリ内の任意の場所から実行する。

```bash
wt new <task> [--base <ref>] [--no-claude]  # worktree + workspace + Claude Code 起動
wt bootstrap [<path>]                        # 既存 worktree に欠落ファイルを補完
wt open <task>                               # 既存 worktree を workspace として開き直す
wt list                                      # worktree ↔ workspace の対応一覧
wt rm <task> [--force]                       # worktree / workspace / ブランチを削除
```

- worktree は native と同じ `<repo>/.claude/worktrees/<task名>` に、ブランチ `worktree-<task名>` で作られる (`WT_HOME` を設定すると従来の集約置き場 `$WT_HOME/<repo名>/<task名>`)。
- `--base` 省略時は本体 checkout の現在ブランチから分岐する。
- herdr サーバが起動していなければ git worktree の作成だけにフォールバックする。

## native worktree との使い分け（統一方針）

Claude Code 自身も worktree を作る（`claude --worktree`、subagent の `isolation: worktree`、desktop の並列セッション）。`wt` と native は**同じ置き場・同じブランチ命名**（`<repo>/.claude/worktrees/<name>/`、ブランチ `worktree-<name>`）を共有し、同じ worktree を指す。違うのは作り方と補完方法で、native は fresh コピー中心・base 既定 `origin/HEAD`、`wt` は herdr workspace 起動と symlink 補完込み・base 既定は本体の現在ブランチ。同じ実体なので native で作った worktree を `wt open` / `wt bootstrap` / `wt rm` でそのまま扱える。単一の補完 hook が両方をまたげないため、**`.worktreeinclude` を「持ち込むファイル一覧の唯一の正」**として両方で共有する。

- **`.worktreeinclude`**（repo root、**要コミット**）: fresh checkout に要る gitignore 済みファイルを `.gitignore` 構文で列挙。native はこれを読んで**自動でコピー**し、`wt` の repo フックはこれを読んで本体から**symlink 共有**する（同じ一覧を 2 通りに消費）。
- **`scripts/worktree-setup`**（repo フック、**要コミット**）: コピーで表せない補完＝依存インストール・環境 symlink 再生成・native rebuild。`wt` はこれに委譲する。**native はこのフックを呼ばない**ので、依存が要る repo の native worktree は作成後に `wt bootstrap <path>` で仕上げる。
- base の既定が違う（native=`origin/HEAD` fresh / `wt`=本体の現在ブランチ）。揃えたいときは settings に `"worktree": { "baseRef": "head" }`。
- `.worktreeinclude` / フックは**コミット必須**。native の fresh base は未コミットファイルを見ない。

使い分け: 軽量・使い捨て・subagent 分離は native（`claude --worktree`）、herdr workspace 起動や欠落補完込みで立ち上げたいときは `wt`。同じ場所を指すので、native で作ったものを後から `wt open` / `wt bootstrap` で仕上げてもよい。

## bootstrap の分担

共通処理 (wt 本体):

1. 本体の `.env` を worktree へ symlink (実体ファイルが既にあれば触らない)
2. `.claude/settings.local.json` をコピー (Claude Code の許可設定の引き継ぎ)
3. repo フックがあれば委譲、無ければ lockfile から検出した package manager で依存インストール

repo 固有処理 (repo の `scripts/worktree-setup`、実行可能ファイル):

- cwd = worktree で呼ばれ、`WT_MAIN_ROOT` (本体 checkout) と `WT_TARGET` (worktree) が渡される
- 依存インストールを**含めて**フック側の責任 (フックがあると wt は install しない)
- 推奨実装: `.worktreeinclude` を読んで各エントリを本体から symlink（`.claude/` 配下は machine-local なので symlink せずコピー管理に委ねる）→ 環境 symlink の再生成 → 依存インストール。`WT_SKIP_DEPS=1` で config 補完だけ回せると再補完が速い
- 典型的な内容: gitignore された secrets/credentials の symlink 共有、ローカル DB のコピー独立、native addon の補完
- monorepo での参照実装イメージ: gitignore された config の symlink・環境固有ファイルの symlink 再生成・各パッケージ (`client` / `infra` 等) の `npm ci`・Python パッケージの `uv sync` を 1 つのフックにまとめる

## 既知の注意点

- `~/.npmrc` に `ignore-scripts=true` があるため、`npm ci` だけでは native addon (better-sqlite3 等) がビルドされない。フックで `npm rebuild <pkg> --ignore-scripts=false --foreground-scripts` するか、本体のビルド済み `.node` をコピーする。
- Claude Code が自分で作る worktree (`.claude/worktrees/*`) も同じ欠落を持つ。テストや実行が必要なら `wt bootstrap <path>` で補完する。
- 本体 checkout の未コミット変更は worktree に入らない (worktree はコミット済み ref から分岐する)。
- gitignore で共有ディレクトリを無視する場合、symlink には末尾スラッシュ付きパターン (`secrets/`) が一致しない。`secrets` のように書く。
