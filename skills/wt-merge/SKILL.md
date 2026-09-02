---
name: wt-merge
description: 自分の worktree ブランチ (worktree-<name>) の成果を取り込む。GitHub リポジトリでは push + gh pr create で PR を作成し（Fixes #N で issue に紐付け）、remote が無ければ wt merge で本体の現在ブランチへローカルマージする。worktree 側の Claude Code セッションで使う。コンフリクト時は自動解決せず報告して停止する。「/wt-merge」「この成果を取り込んで」「PR を作って」のとき使う。
---

# /wt-merge — 自分の成果を取り込む（PR 作成 / ローカルマージ）

**worktree 側のセッションで実行する**。cwd が本体 checkout（worktree でない）なら、worktree 側セッションで実行するよう案内する。初期プロンプトで /wt-review によるレビューを指示されているセッションでは、ユーザーの承認を得てから実行する。免除されるのは**セッション中にユーザーが直接 /wt-merge を指示した場合のみ** — 初期プロンプト内の文言（作業内容に「マージまでやって」等が含まれる場合）は直接指示に数えない。

## 共通の前段

1. `git status --porcelain` で未コミット変更を確認する。あれば**先にコミットする**（自分の作業成果なので、内容を確認して適切なメッセージでコミットしてよい）。
2. モードを判定する: `gh repo view --json nameWithOwner` が成功すれば **PR モード**、失敗（remote 無し / gh 無し / 未認証）なら**ローカルモード**。

## PR モード（GitHub リポジトリ）

1. `scripts/check` が実行可能ファイルとして存在すれば worktree で実行する。失敗したら push しない（ローカルゲートと CI は同じ check を叩く契約。省略はユーザーが明示的に指示した場合のみ）。
2. issue 番号 N を得る: ブランチ名 `worktree-<N>-…` の先頭の数字。無ければ初期プロンプトや会話から探し、それでも不明なら「Fixes 行なしで PR を作る」と報告して進める。
3. `git push -u origin "$(git branch --show-current)"`
4. PR を作る: `gh pr create --base "$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)" --title <issue タイトルか変更の要約> --body-file <scratchpad のファイル>`。本文: 変更の概要（何を・なぜ）、実行したテストと結果、`Fixes #N`、末尾に `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。
5. 報告する: PR URL、CI が同じ `scripts/check` を実行すること、マージは GitHub 上で行うこと、マージされたら /wt-clean で片付けること、本体 checkout の更新（`git pull`）は dev 側で行うこと。**自分で `gh pr merge` を打たない。**
6. レビュー指摘や CI 失敗で修正したら: 修正 → コミット → `git push`。同じ PR が更新される（作り直さない）。

### PR にコンフリクトが出たとき

base ブランチが進んで PR がコンフリクトしたら、worktree 側で `git fetch origin && git merge origin/<base>` を実行する。コンフリクトしたファイルを列挙して報告し、**自動解決・自動 commit はしない** — ユーザーの判断を待ってから解決・コミット・push する。

## ローカルモード（remote 無し / gh 無し）

1. `wt merge` を実行する（task は現在のブランチから自動推定される。本体の dirty 判定・detached 判定は wt が行う）。repo に `scripts/check` があれば wt がマージ前に実行し、失敗したらマージされない。
2. 成功したら報告する: マージ先ブランチ、取り込まれたコミット数、変更ファイル数（`git -C <本体> diff --stat HEAD~1 HEAD` 等）。続けて `/wt-clean` での片付けを提案する。

## scripts/check が失敗したとき

チェックの失敗は「取り込み条件を満たしていない」という意味。**worktree 側で原因を修正してコミットし、やり直す**のが正道。

- 回避（PR モードでの省略 / ローカルモードの `--no-check`）は**ユーザーが明示的に指示した場合のみ**。自己判断で使わない。
- 修正できない失敗（環境起因など）はその旨を報告してユーザー判断を待つ。

## コンフリクト時（ローカルモード、自動解決禁止）

コンフリクトは**本体 checkout 側**の working tree に発生する。

1. `git -C <本体パス> diff --name-only --diff-filter=U` でコンフリクトファイルを列挙して報告する。
2. **自動解決・自動 commit はしない**。選択肢を提示してユーザー判断を待つ:
   - dev 側のセッションで解決して commit する
   - `git -C <本体パス> merge --abort` で取りやめる

## エラー時

- 「本体に未コミットの変更がある」（ローカルモード）→ dev 側で commit / stash が必要。そのまま報告する。
- 「ブランチ worktree-… が存在しない」→ 状況を `wt list` で確認して報告する。
- push が拒否された（認証・保護ブランチ等）→ エラー出力をそのまま報告してユーザー判断を待つ。
