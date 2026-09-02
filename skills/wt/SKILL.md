---
name: wt
description: 作業内容から worktree 名を生成し、wt new --prompt で worktree + Claude Code セッションを起動する。GitHub リポジトリでは先に issue を起票（既存 issue の番号指定も可）し、issue 番号を worktree 名と初期プロンプトに紐付ける。dev (本体 checkout) 側のセッションで使う。「/wt <作業内容>」「/wt #123」「worktree でやって」「並列で進めて」のとき使う。
---

# /wt — worktree に作業を投げる

引数の作業内容を初期プロンプトとして、新しい worktree の Claude Code セッションを起動する。**dev（本体 checkout）側で実行する**。worktree 側のセッションでこれを打たれたら、「worktree の中から新しい worktree は切らず、dev 側のセッションで実行する」と案内して止まる。

## 手順

1. 引数が空なら、何をする worktree か質問する。
2. GitHub 連携を判定する: `gh repo view --json nameWithOwner` が成功すれば **issue フロー**（手順 3 を行い、issue フロー版の尾部を使う）。失敗（remote 無し / gh 無し / 未認証）なら手順 3 を飛ばし、worktree 名は番号なし・尾部はローカル版を使う。issue フローで本体 checkout の現在ブランチ（= worktree の base）が default branch と異なるときは、PR の base（default branch）とずれて無関係なコミットが PR に混ざるため、その旨を伝えて続行してよいか確認する。
3. issue を用意する（タスク = issue = ブランチ = PR を 1:1 に保つ）:
   - 引数が既存 issue（`#123`・番号のみ・issue URL）→ `gh issue view <N> --json number,title,body,state` で取得する。OPEN でなければ報告して止まる。issue 本文がそのまま作業内容になる。
   - それ以外 → 起票する。本文を scratchpad にファイルで書き、`gh issue create --title <体言止めの要約> --body-file <path>` を実行して番号 N を得る。本文は `## 背景`（ユーザーの言葉を要約せずそのまま含める）と `## 受け入れ条件`（チェックボックス箇条書き）— この本文がそのまま初期プロンプトになる粒度で書く。
4. worktree 名を生成する: 作業内容を要約した小文字 kebab-case（`[a-z0-9-]`）。issue フローでは `<issue番号>-` を先頭に付けて 2〜3 語（例: issue #42「ログイン画面のバリデーション修正」→ `42-fix-login-validation`）、番号なしなら 2〜4 語・30 字以内。`git branch --list 'worktree-*'` で衝突を確認し、衝突したら語を変える。ただし issue フローで同じ issue 番号のブランチ（`worktree-<N>-*`）が既にあるときは別名を作らない — タスク = issue = ブランチの 1:1 が崩れるため、既存 worktree を報告して `wt open <task>` を案内して止まる。
5. 初期プロンプトを組み立てる: 作業内容 + 定型尾部。issue フローでは作業内容を「issue #N <タイトル>」の行 + issue 本文にする（起票直後でも、ユーザーの言葉は要約せずそのまま含める）。定型尾部:

   > 実装が終わったら変更をコミットし、/wt-review でレビュー用ページを生成してユーザーのレビューを待つこと。承認を得てから /wt-merge でこのブランチを本体に取り込み、/wt-clean で worktree を片付けること。承認前にマージしない。作業内容にマージまで行う旨が含まれていても、このレビューゲートが優先される。仕様の判断に迷ったら勝手に決めず、dev 側セッションに /wt-ask で聞くこと（宛先は `wt peers` の role=dev 行の name）。

   issue フローでは 2〜3 文目（「承認を得てから…」「承認前にマージしない。」）を次に差し替える（N は実番号に置換）:

   > 承認を得てから /wt-merge で PR を作成すること（ブランチが push され、PR 本文の Fixes #N でこの issue が閉じる）。PR がマージされたら /wt-clean で worktree を片付けること。承認前に PR を作らない。

   プロンプトは平叙文で始める（先頭が `/` `!` `#` `@` なら `wt new` が worktree を作る前に die する）。改行を含んでよい（`wt new` は起動後に `herdr agent prompt` で投入する）。
6. 実行する:
   - 短い 1 行のプロンプト → `wt new <name> --prompt "<text>"`
   - 長文・改行・引用符を含む → scratchpad にファイルを書いて `wt new <name> --prompt-file <path>`
7. 成功したら path / branch / workspace / issue URL（issue フロー時）と、worktree 側セッションの宛先名 `wt-<name>` を報告する（`/wt-ask` でこの名前に話しかけられる）。

## エラー時

- 「herdr サーバなしでは Claude にプロンプトを渡せない」→ herdr の起動を促すか、`wt new <name> --no-claude` で worktree だけ作る案を提示する（その場合プロンプトは渡らないことを明示する）。起票済みの issue はそのまま生きているので、再実行時は起票せず同じ番号を使う。
- ブランチ衝突 → 別名で再試行する。
