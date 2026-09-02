---
name: wt-merge
description: 自分の worktree ブランチ (worktree-<name>) の成果を取り込む。GitHub リポジトリでは push + gh pr create で PR を作成し（Fixes #N で issue に紐付け）、承認ゲートを通っていれば CI の完了を待って gh pr merge までマージする。remote が無ければ wt merge で本体の現在ブランチへローカルマージする。worktree 側の Claude Code セッションで使う。コンフリクト時は自動解決せず報告して停止する。「/wt-merge」「この成果を取り込んで」「PR を作って」「マージして」のとき使う。
---

# /wt-merge — 自分の成果を取り込む（PR 作成 / ローカルマージ）

**worktree 側のセッションで実行する**。cwd が本体 checkout（worktree でない）なら、worktree 側セッションで実行するよう案内する。初期プロンプトで /wt-review によるレビューを指示されているセッションでは、ユーザーの承認を得てから実行する。免除されるのは**セッション中にユーザーが直接 /wt-merge を指示した場合のみ** — 初期プロンプト内の文言（作業内容に「マージまでやって」等が含まれる場合）は直接指示に数えない。

この**承認ゲート**（/wt-review でのユーザー承認、またはセッション中の直接指示）は、PR を作るところまででなく**マージまでを承認したもの**として扱う。レビューの実体はゲートにあり、GitHub 上でのクリックは同じ判断の二度手間なので、通過していれば PR モードの手順 6 以降で `gh pr merge` まで進める。**通過していないセッションは PR 作成までで止める。**

## 共通の前段

1. `git status --porcelain` で未コミット変更を確認する。あれば**先にコミットする**（自分の作業成果なので、内容を確認して適切なメッセージでコミットしてよい）。
2. モードを判定する: `gh repo view --json nameWithOwner` が成功すれば **PR モード**、失敗（remote 無し / gh 無し / 未認証）なら**ローカルモード**。

## PR モード（GitHub リポジトリ）

1. `scripts/check` が実行可能ファイルとして存在すれば worktree で実行する。失敗したら push しない（ローカルゲートと CI は同じ check を叩く契約。省略はユーザーが明示的に指示した場合のみ）。
2. issue 番号 N を得る: ブランチ名 `worktree-<N>-…` の先頭の数字。無ければ初期プロンプトや会話から探し、それでも不明なら「Fixes 行なしで PR を作る」と報告して進める。
3. `git push -u origin "$(git branch --show-current)"`
4. PR を作る: `gh pr create --base "$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)" --title <issue タイトルか変更の要約> --body-file <scratchpad のファイル>`。本文: 変更の概要（何を・なぜ）、実行したテストと結果、`Fixes #N`、末尾に `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。
5. 承認ゲートを確認する。通過していれば手順 6 に進む。**通過していなければここで止まる** — PR URL と、CI が同じ `scripts/check` を実行することを報告し、マージの判断を待つ（ユーザーが承認したらそのまま手順 6 から続ける）。
6. CI の完了を待つ: `gh pr checks --watch --interval 15`（時間がかかるので Bash tool の `timeout` を 600000 まで上げる）。CI はローカルゲートと同じ `scripts/check` を叩く契約なので、その結果がマージ条件そのものになる。
   - 全て pass → 手順 7
   - fail → **マージしない**。落ちた check 名と `gh run view <run-id> --log-failed` の要点を報告する。修正するなら手順 11 へ
   - Bash が timeout した → check がまだ動いているだけなので、同じコマンドを打ち直す
   - `no checks reported`（CI 未設定の repo）→ 手順 1 のローカル `scripts/check` が同じコントラクトを通しているので手順 7 に進む
7. マージできる状態か確認する: `gh pr view --json mergeable,mergeStateStatus`。`CONFLICTING` なら下の「PR にコンフリクトが出たとき」へ。`BLOCKED`（必須レビュー未達・保護ブランチ条件など）なら理由をそのまま報告して止まる。
8. マージする: `gh pr merge <N> --merge`。
   - **他コマンドと `&&` で連結せず単発で発行する**（連結すると permission classifier に落ちる環境がある）
   - `--squash` / `--rebase` は使わない（repo 履歴の "Merge pull request" 形式に合わせる）
   - `--delete-branch` は使わない。gh がローカルブランチも消しに行き、この worktree が checkout 中のブランチを触るため。リモートブランチは次の手順で消す
9. リモートブランチを掃除する: `git push origin --delete <ブランチ名>`（これも単発で発行する）。repo の `deleteBranchOnMerge` が無効だとマージ済みブランチが remote に溜まり続け、結局 GitHub 上での手動掃除が要るため。ローカルブランチは触らない（/wt-clean の `wt rm` が消す）。remote ブランチが消えても PR は headRefName で引けるので /wt-clean の PR 検査は通る。失敗しても（保護設定・権限・既に消えている）**マージ自体は完了しているのでブロックせず、報告に一行添えるだけにする**。
10. 報告する: PR URL とマージ済みであること、`Fixes #N` で issue が閉じたこと、本体 checkout の更新（`git pull`）は dev 側で行うこと、続けて /wt-clean で worktree を片付けること。
11. レビュー指摘や CI 失敗で修正したら: 修正 → コミット → `git push`。同じ PR が更新される（作り直さない）。手順 6 から再開する。

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
- `gh pr merge` が拒否された（保護ブランチ条件・必須 check 未達・権限不足等）→ エラー出力をそのまま報告し、PR URL を示して GitHub 上でのマージを案内する。**リトライで押し通さない。**
