---
name: wt-clean
description: 自分の worktree の未コミット変更と取り込み状態（PR の MERGED / 本体への未マージコミット）を検査し、クリーンなら wt rm で worktree / workspace / ブランチを片付けてセッションを閉じる。worktree 側の Claude Code セッションで使う。「/wt-clean」「この worktree を片付けて」のとき使う。
---

# /wt-clean — 自分の worktree を片付けて閉じる

**worktree 側のセッションで実行する**。実行に成功すると workspace ごと閉じ、このセッション自体が終了する。cwd が本体 checkout なら、`wt rm <task>` と task を明示するか、worktree 側セッションで実行するよう案内する。

## 手順

1. モードを判定する: `gh pr view --json state,headRefOid,url` で現在ブランチの PR を調べる。PR があれば **PR モード**、無ければ（gh 無し / remote 無し / PR 未作成）**ローカルモード**。
2. **PR モードの検査（3 点）**:
   - 未コミット変更が無い: `git status --porcelain` が空
   - PR がマージ済み: state が `MERGED`
   - HEAD が PR に入っている: `git rev-parse HEAD` が headRefOid と一致
   3 点すべて満たしたら: 先に完了報告を出す（PR URL と、本体 checkout の更新は dev 側で `git pull` する旨を含める）。**報告を出してから** `wt rm --force` を実行する。ここでの `--force` は例外的に正当 — PR マージ後も本体 checkout は pull 前なので、`git branch -d` がブランチを「未マージ」と誤認して残すため。3 点を検証済みの場合に限る。
   満たさないときは中断して報告する:
   - state が `OPEN` → 「PR がまだマージされていない」。URL を示して待つ（headRefOid 不一致は push 漏れ — `git push` で PR を更新してから待つ）。
   - state が `MERGED` だが未コミット変更がある、または HEAD が headRefOid と不一致 → マージ後に積んだ余剰の変更。push しても merged PR には入らない。新しい issue / ブランチに切り出すか、ユーザーが破棄を明示した場合のみ破棄する。
   - state が `CLOSED`（マージされず閉じた）→ 破棄扱い。ユーザーが破棄を明示した場合のみ `wt rm --force`。
3. **ローカルモードの検査（2 点）**:
   - 未コミット変更: `git status --porcelain`
   - 本体に未取り込みのコミット: `git log --oneline $(git -C <本体パス> rev-parse HEAD)..HEAD`（本体パスは `git rev-parse --path-format=absolute --git-common-dir` の親ディレクトリ）
4. ローカルモードで**両方空**なら: 先に完了報告を出す（「worktree を片付けます。この workspace は閉じます」）。**報告を出してから** `wt rm` を実行する — 実行すると workspace ごと閉じてセッションが終了するため、後から報告はできない。task は現在のブランチから自動推定される。
5. ローカルモードで**どちらか非空**なら中断し、失われるものを具体的に列挙する（変更ファイル一覧 / コミット一覧）。選択肢を提示する:
   - `/wt-merge` で本体に取り込んでから片付ける
   - 未コミット変更をコミットしてから `/wt-merge`
   - 破棄してよいとユーザーが**明示した場合のみ** `wt rm --force`

## 禁止事項

- `--force` を自己判断で使わない。例外は PR モードで 3 点（未コミット無し / MERGED / HEAD 一致）を検証済みの場合のみ。未マージ・未コミットの作業を黙って消さない。
