---
name: wt
description: 作業内容から worktree 名を生成し、wt new --prompt で worktree + Claude Code セッションを起動する。dev (本体 checkout) 側のセッションで使う。「/wt <作業内容>」「worktree でやって」「並列で進めて」のとき使う。
---

# /wt — worktree に作業を投げる

引数の作業内容を初期プロンプトとして、新しい worktree の Claude Code セッションを起動する。**dev（本体 checkout）側で実行する**。worktree 側のセッションでこれを打たれたら、「worktree の中から新しい worktree は切らず、dev 側のセッションで実行する」と案内して止まる。

## 手順

1. 引数が空なら、何をする worktree か質問する。
2. worktree 名を生成する: 作業内容を要約した小文字 kebab-case（`[a-z0-9-]`、2〜4 語・30 字以内。例:「ログイン画面のバリデーション修正」→ `fix-login-validation`）。`git branch --list 'worktree-*'` で衝突を確認し、衝突したら `-2` などを付ける。
3. 初期プロンプトを組み立てる: 作業内容（ユーザーの言葉を要約せずそのまま含める）+ 定型尾部:

   > 実装が終わったら変更をコミットし、/wt-review でレビュー用ページを生成してユーザーのレビューを待つこと。承認を得てから /wt-merge でこのブランチを本体に取り込み、/wt-clean で worktree を片付けること。承認前にマージしない。作業内容にマージまで行う旨が含まれていても、このレビューゲートが優先される。

   プロンプトは平叙文で始める（`-` 始まりは claude がフラグと誤認するため禁止）。
4. 実行する:
   - 短い 1 行のプロンプト → `wt new <name> --prompt "<text>"`
   - 長文・改行・引用符を含む → scratchpad にファイルを書いて `wt new <name> --prompt-file <path>`
5. 成功したら path / branch / workspace を報告する。

## エラー時

- 「herdr サーバなしでは Claude にプロンプトを渡せない」→ herdr の起動を促すか、`wt new <name> --no-claude` で worktree だけ作る案を提示する（その場合プロンプトは渡らないことを明示する）。
- ブランチ衝突 → 別名で再試行する。
