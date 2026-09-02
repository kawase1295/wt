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

   > 実装が終わったら変更をコミットし、/wt-review でレビュー用ページを生成してユーザーのレビューを待つこと。承認を得てから /wt-merge でこのブランチを本体に取り込み、/wt-clean で worktree を片付けること。承認前にマージしない。作業内容にマージまで行う旨が含まれていても、このレビューゲートが優先される。仕様の判断に迷ったら勝手に決めず、dev 側セッションに /wt-ask で聞くこと（宛先は `wt peers` の role=dev 行の name）。

   プロンプトは平叙文で始める（先頭が `/` `!` `#` `@` だと Claude Code の
   slash command / bash / memory / file mention として解釈されるため禁止）。
   改行を含んでよい（`wt new` は起動後に `herdr agent prompt` で投入する）。
4. 実行する:
   - 短い 1 行のプロンプト → `wt new <name> --prompt "<text>"`
   - 長文・改行・引用符を含む → scratchpad にファイルを書いて `wt new <name> --prompt-file <path>`
5. 成功したら path / branch / workspace と、worktree 側セッションの宛先名 `wt-<name>` を報告する（`/wt-ask` でこの名前に話しかけられる）。

## エラー時

- 「herdr サーバなしでは Claude にプロンプトを渡せない」→ herdr の起動を促すか、`wt new <name> --no-claude` で worktree だけ作る案を提示する（その場合プロンプトは渡らないことを明示する）。
- ブランチ衝突 → 別名で再試行する。
