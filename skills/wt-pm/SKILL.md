---
name: wt-pm
description: dev (本体 checkout) 側のメインセッションがオーケストレータとして、作業内容の起票（親 / 子の分解、ユーザー確認あり）→ wt loop への投入 → events.jsonl の監視 → needs-human の仲介 → 報告を回す契約。メインは実装しない。/wt-loop・/wt-detail・/wt-split・/wt-ask を部品として組み合わせる。「/wt-pm <作業内容>」「進めておいて」「オーケストレートして」「サブエージェントに任せて」のとき使う。
---

# /wt-pm — メインが起票・投入・監視・仲介・報告を回す

ユーザーと対話しているメインのセッションを、実装者ではなくオーケストレータとして振る舞わせる。実装は `wt loop` の worker（headless claude）か、`wt new` で開いた worktree 側のセッションが担う。メインが行うのは **起票・分解・投入・監視・仲介・報告だけ**。

部品: 分解と起票の書式は `/wt-split`、単一タスクの調査と起票は `/wt-detail`、loop の起動・停止の作法は `/wt-loop`、worktree 側セッションとの会話は `/wt-ask` に従う。この skill はそれらをつなぐ順序と、各段階でユーザーに返すかどうかの線引きを定める。

## 1. 役割と実行する側

- **dev（本体 checkout）側で実行する。** `git rev-parse --git-dir` と `--git-common-dir` が異なる（linked worktree の中）なら、「/wt-pm は dev 側のセッションで使う。本体 checkout のセッションで打ち直してほしい」と案内して止まる。
- `gh repo view --json nameWithOwner` が失敗する repo（GitHub 連携なし）では loop も issue も使えない。その旨を伝えて止まる。
- メインは issue の実装を始めない。ファイルを直したくなったら、それは起票すべき作業である。

## 2. 起票（ユーザー確認あり）

1. 作業内容からタスクの数を見積もる。
   - 複数タスク → 親 / 子の分解案を作る。分解の原則（縦に切る / 同じファイル群を触る子は直列 / 子は `scripts/check` が通る最小の完結単位）と本文の書式（`## 背景` に「親 issue: #N」、`## 受け入れ条件` にチェックボックス、親の `## 子タスク` に「（#M のあと）」の依存表記）は `/wt-split` に従う。
   - 単一タスク → `/wt-detail` の要領でコードベースを調査し、不明点を詰めてから 1 本の issue にする。親は作らない。
2. 受け入れ条件は **AI だけで完結する粒度** で書く（テストか静的検査で合否が決まる、worktree の中で終わる）。次が混じる項目は受け入れ条件から外し、`needs-human` 相当としてまとめて **先に** ユーザーに返す:
   - 本番環境での作業（デプロイ・本番データ・課金が発生する操作）
   - 人への依頼（権限付与・レビュー依頼・社外との調整）
   - 未決の仕様判断（どちらを選ぶか決まっていない、ユーザーの好みで決まる）

   ユーザーが「それも起票して」と言ったら、その issue には `needs-human` ラベルを付けて loop の対象外にする。
3. 分解案（子ごとのタイトル・受け入れ条件の骨子・依存）と、外した `needs-human` 相当の項目を提示し、ユーザーの確認を得る。選択肢で聞けるなら AskUserQuestion、そうでなければ本文に案を示して返答を待つ。**確認なしに起票しない。**
4. 確認が取れたら `/wt-split` の手順 4 と同じ書式で起票する（単一なら `gh issue create` 1 本）。loop に乗せる issue には対象ラベル（既定 `wt-loop`）を付けるか、投入時に番号で指定する。

## 3. 投入（自律）

ここから先はユーザーの確認を求めない（止めたいときは `wt loop --stop` でいつでも止まる）。

1. 経路を分ける。次のどちらかに当たる issue は **対話経路**、それ以外は **loop 経路** にする:
   - ユーザーが「仕様判断が多い」と言った issue
   - 受け入れ条件に「要相談」がある issue
2. **対話経路**: `/wt` の命名規約（`<N>-` + 2〜3 語、25 字以内）で `wt new <name> --prompt-file <path>` を実行し、herdr セッションを開く。以降の仕様判断は `/wt-ask` でそのセッションと会話して詰める（判断がユーザーの好みで決まるなら、メインがユーザーに聞いて返す）。
3. **loop 経路**:
   1. `wt loop doctor` を実行する。`NG` があれば、その行の直し方をユーザーに示して止まる（ラベルが無いだけなら `wt loop doctor --fix-labels` で作れる、と添える）。
   2. `wt loop <親N> --dry-run` で対象と飛ばした理由を確認する（単一 issue なら `<親N>` の代わりにその番号）。対話経路に回した子があるときは、loop に拾わせないよう親番号ではなく loop 経路の子の番号を並べる。出力の `state: <path>` を控える。対象が無ければ理由を報告して止まる。
   3. そのまま `wt loop <親N>`（dry-run と同じ引数）を Bash tool の `run_in_background` で起動する。background のシェルはログインシェルの PATH を引き継がないことがあるので、**起動コマンドで PATH を保証する**: memory（`~/.claude/projects/<repo>/memory/`）に PATH のメモがあればその `export PATH=...` を前置する。無ければ手元の `command -v claude node wt` で見つかったディレクトリを `export PATH="<dir>:...:$PATH"` として前置する。どれかが見つからなければ起動せず、導入をユーザーに依頼して止まる。
4. 起動を 1 回だけ報告する: 対象 issue、経路の内訳、state の場所、止め方（`/wt-loop stop`）。

## 4. 監視（自律）

- state ディレクトリの `events.jsonl`（1 行 1 イベントの JSON。driver が追記する）を **Monitor tool** で追う。コマンド:

  ```
  tail -F -n 0 <state>/events.jsonl | grep --line-buffered -E '"event":"(merged|needs_human|failed|stopped|run_finished)"'
  ```

  timeout は 30 分。切れたら同じコマンドで再アームする（`run_finished` か `stopped` を受け取るまで繰り返す）。
- `stage` / `round` のイベントは grep で落とす。途中経過はユーザーに報告しない。
- **ScheduleWakeup は使わない。** 起こすのは Monitor の通知であり、ポーリングしない。
- `events.jsonl` が無い古い wt では、`/wt-loop` と同じく `loop.log` を `grep --line-buffered -E 'マージ完了|needs-human|stopped|failed|終了:|ERROR'` で追う。

## 5. 仲介

`needs_human` を受け取ったら:

1. state の `<N>/round-K.worker.md`（K は最後のラウンド）を読み、`BLOCKED:` の理由を把握する。worker が BLOCKED を出していない（ラウンド上限・CI 待ち上限・push / merge 拒否）なら、issue に driver が付けたコメントの理由を読む。**理由を読まずに再投入しない。**
2. 理由の種類で分ける:
   - **仕様・判断の問い** → ユーザーに **1 問で** 聞く。選択肢が作れるなら AskUserQuestion を使う。答えを `gh issue comment <N> --body-file <path>` で issue に書き（再開時に driver が worker へ「前回からの引き継ぎ」として渡す）、`gh issue edit <N> --remove-label needs-human` してから `wt loop <N>` で再投入する（起動は手順 3 と同じく PATH を保証して `run_in_background`。残った worktree と session を再利用して続きから進む）。
   - **環境起因**（PATH が通っていない、ツールの欠品、認証切れ） → ユーザーに直してもらう手順を具体的に示す。直ったと言われたら、ラベルを外して `wt loop <N>` で再投入する。
3. 同じ repo で loop は 1 本しか動かない（lock）。先の run がまだ動いているなら、再投入はその `run_finished` を待ってから行う。

## 6. 報告

黙るのが既定。報告するのは次だけ:

| イベント | 報告 |
| --- | --- |
| `merged` | PR URL と所要時間・コストを 1 行 |
| `needs_human` | 手順 5 の 1 問（報告ではなく質問として） |
| `run_finished` | サマリ（処理した件数 / マージした件数 / needs-human の件数と番号） |
| `failed` | 「claude か gh が動いていない疑い（利用上限・API 障害・認証切れ）」として原因の確認をユーザーに促す。直ったら `wt loop <N>` で再開できる、と添える |
| `stopped` | 止まったことと、残った worktree があれば再開の仕方 |

それ以外（`stage` / `round`、同じ内容の繰り返し）は黙る。親の子が全部 CLOSED になったら、親を閉じてよいかをユーザーに 1 回だけ聞く（loop は親を閉じない）。

## 7. 禁止事項

- メインが worktree（`wt new` で開いたものも loop のものも）で実装しない。手を出すと worker / worktree 側と競合する。
- needs-human の理由（`round-K.worker.md` と issue コメント）を読まずに、ラベルだけ外して再投入しない。
- 起票をユーザーの確認なしに行わない（投入以降は自律でよいが、起票は取り消しにくい）。
- loop を `wt loop --stop` 以外の方法（background タスクの kill、プロセスの kill）で止めない。
- `wt loop` / `wt new` を worktree 側のセッションから起動しない。
