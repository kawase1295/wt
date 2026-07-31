---
name: wt-merge
description: 自分の worktree ブランチ (worktree-<name>) を本体の現在ブランチにマージする。worktree 側の Claude Code セッションで使う。コンフリクト時は自動解決せず報告して停止する。「/wt-merge」「この成果を本体に取り込んで」のとき使う。
---

# /wt-merge — 自分の成果を本体に取り込む

**worktree 側のセッションで実行する**。cwd が本体 checkout（worktree でない）なら、`wt merge <task>` と task を明示するか、worktree 側セッションで実行するよう案内する。初期プロンプトで /wt-review によるレビューを指示されているセッションでは、ユーザーの承認を得てから実行する。免除されるのは**セッション中にユーザーが直接 /wt-merge を指示した場合のみ** — 初期プロンプト内の文言（作業内容に「マージまでやって」等が含まれる場合）は直接指示に数えない。

## 手順

1. `git status --porcelain` で未コミット変更を確認する。あれば**先にコミットする**（自分の作業成果なので、内容を確認して適切なメッセージでコミットしてよい）。
2. `wt merge` を実行する（task は現在のブランチから自動推定される。本体の dirty 判定・detached 判定は wt が行う）。
3. 成功したら報告する: マージ先ブランチ、取り込まれたコミット数、変更ファイル数（`git -C <本体> diff --stat HEAD~1 HEAD` 等）。続けて `/wt-clean` での片付けを提案する。

## コンフリクト時（自動解決禁止）

コンフリクトは**本体 checkout 側**の working tree に発生する。

1. `git -C <本体パス> diff --name-only --diff-filter=U` でコンフリクトファイルを列挙して報告する。
2. **自動解決・自動 commit はしない**。選択肢を提示してユーザー判断を待つ:
   - dev 側のセッションで解決して commit する
   - `git -C <本体パス> merge --abort` で取りやめる

## エラー時

- 「本体に未コミットの変更がある」→ dev 側で commit / stash が必要。そのまま報告する。
- 「ブランチ worktree-… が存在しない」→ 状況を `wt list` で確認して報告する。
