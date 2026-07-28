---
name: wt-clean
description: 自分の worktree の未コミット変更・未マージコミットを検査し、クリーンなら wt rm で worktree / workspace / ブランチを片付けてセッションを閉じる。worktree 側の Claude Code セッションで使う。「/wt-clean」「この worktree を片付けて」のとき使う。
---

# /wt-clean — 自分の worktree を片付けて閉じる

**worktree 側のセッションで実行する**。実行に成功すると workspace ごと閉じ、このセッション自体が終了する。cwd が本体 checkout なら、`wt rm <task>` と task を明示するか、worktree 側セッションで実行するよう案内する。

## 手順

1. 検査する（2 点）:
   - 未コミット変更: `git status --porcelain`
   - 本体に未取り込みのコミット: `git log --oneline $(git -C <本体パス> rev-parse HEAD)..HEAD`（本体パスは `git rev-parse --path-format=absolute --git-common-dir` の親ディレクトリ）
2. **両方空**なら: 先に完了報告を出す（「worktree を片付けます。この workspace は閉じます」）。**報告を出してから** `wt rm` を実行する — 実行すると workspace ごと閉じてセッションが終了するため、後から報告はできない。task は現在のブランチから自動推定される。
3. **どちらか非空**なら中断し、失われるものを具体的に列挙する（変更ファイル一覧 / コミット一覧）。選択肢を提示する:
   - `/wt-merge` で本体に取り込んでから片付ける
   - 未コミット変更をコミットしてから `/wt-merge`
   - 破棄してよいとユーザーが**明示した場合のみ** `wt rm --force`

## 禁止事項

- `--force` を自己判断で使わない。未マージ・未コミットの作業を黙って消さない。
