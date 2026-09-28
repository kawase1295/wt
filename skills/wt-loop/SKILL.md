---
name: wt-loop
description: ラベル付き issue を人間の操作なしに worktree → headless 実装 → check → AI レビュー → PR → CI → マージ → 片付け → 次の issue、と回す wt loop を、dev (本体 checkout) 側のセッションから起動・監視・停止する。「/wt-loop」「/wt-loop #12 #15」「/wt-loop status」「/wt-loop stop」「ループを回して」「無人で進めて」のとき使う。
---

# /wt-loop — 無人ループを起動・監視・停止する

`wt loop`（bash の driver）を dev 側のセッションから扱う。driver が issue 選択 / worktree 作成 / check / base 取り込み / push / PR / CI 待ち / merge / 本体 pull / 片付けを行い、Claude は headless（`claude -p`）で「実装」(worker) と「レビュー判定」(reviewer) だけを担う。このセッション自身は実装しない。**dev（本体 checkout）側で実行する**。

## 引数

- 空 → ラベル `wt-loop` 付きの open issue を対象にする
- `#12 #15` / 番号 → その issue を対象にする（ラベル不要。CLOSED / needs-human / 進行中は飛ばされる）
- `status` → `wt loop status` で issue ごとの状態を出す
- `stop` → `wt loop --stop` で、今の claude 呼び出しが終わった区切りで止める
- `--max-issues N` `--max-rounds N` `--label <name>` はそのまま `wt loop` に渡す

## 手順（起動）

1. `gh repo view --json nameWithOwner` が失敗する repo では使えない。その旨を伝えて止まる。
2. まず `wt loop --dry-run <引数>` を実行し、起動前の診断（`wt loop doctor` と同じ検査）と対象の一覧・飛ばした理由をユーザーに見せる。診断に `NG` がある（exit 1）なら起動しない — `NG` 行の直し方を示して止まる（ラベルが無いだけなら `wt loop doctor --fix-labels` で作れる、と添える。他の項目は repo の変更なのでユーザーに任せる）。対象が無ければそこで終わる。対象があれば起動に進む（確認は求めない — ループの停止は `/wt-loop stop` でいつでもできる）。
3. `wt loop <引数>` を Bash tool の `run_in_background` で起動する（数時間かかる。foreground で待たない）。標準出力・標準エラーは Bash tool の出力ファイルに残る。
4. 進捗は state ディレクトリの `loop.log` に追記される。パスは `--dry-run` と起動直後の出力にある `state: <path>` の行から取る。Monitor tool で `tail -f <path>/loop.log` し、行動が要る行だけを流す（`grep --line-buffered -E 'マージ完了|needs-human|stopped|failed|終了:|ERROR'`）。
5. 起動を報告する: 対象 issue、state の場所、止め方（`/wt-loop stop`）。以降は Monitor の通知が届いたときに要点だけ伝える（マージされた PR の URL、needs-human に切り出された issue とその理由、`failed` で loop が止まったこと）。

## 手順（status / stop）

- `status`: `wt loop status` の出力をそのまま示す。needs-human の issue には「issue のコメントにある理由を直してからラベルを外し、`/wt-loop #<N>` と番号で再投入すると、残った worktree と session を再利用して続きから進む」と添える。`failed` は claude か gh が動いていなかった疑い（利用上限・API 障害）なので、直ったら `/wt-loop #<N>` と番号指定で再開する（ラベル選択は残った worktree を「進行中」として飛ばす）。
- `stop`: `wt loop --stop` を実行し、「次の区切り（claude 呼び出しの直後 / push の前 / issue の間）で止まる。進行中の worktree は残る」と伝える。即時停止が要るときは Bash tool の background タスクを止める（worktree と state は残るので、後から `/wt-loop #<N>` で続きから回せる）。

## 前提と制約（ユーザーに聞かれたら答える）

- 権限設定は変えない。worker は `--permission-mode acceptEdits` と allowlist（git / テスト / パッケージマネージャ / 読み取り系のシェルコマンド。`bash` / `sh` / `gh` は入れない。`WT_LOOP_EXTRA_TOOLS` で追記）で動く。
- worker は push できない。permission ルールではなく、worker プロセスだけに効く環境で保証する（git の `pushInsteadOf` を環境変数で与えて全 push 先を無効なパスに書き換える + PATH 先頭の `git` shim が `push` / `send-pack` と塞ぎを外す `-c` を拒否 + `GH_CONFIG_DIR` を空にして gh を無認証にする）。worker が書いた `scripts/check` も同じ環境で走らせ、driver の git 操作は worktree の hook を無効にし、共有 `.git/config` を worker が変えていたら needs-human に返す。防ぐのは誤操作で、`Bash(git *)` を許す以上、意図的な回避（絶対パスの実 git、`git -c alias` での任意シェル）までは防がない。push / PR / merge は driver が自分の環境の git / gh で行う。
- worker と reviewer は別セッション。reviewer には diff と issue 本文と合否基準だけを渡す（実装の経緯は渡さない）。minor のみ PASS、blocker / major は FAIL。迷ったら FAIL。
- 落ちた工程（未コミット / コンフリクト / scripts/check / レビュー FAIL / CI）はその内容を同じ worker セッションに `--resume` で渡して次ラウンド。上限（既定 3）超過、worker の `BLOCKED:`、push / merge の拒否、CI 待ちの上限（既定 30 分）で issue に `needs-human` ラベルとコメント（理由・worktree・state の場所）を付けて次の issue へ進む。worktree は残る。worker が起動直後に異常終了したら（利用上限・API 障害の疑い）その issue を `failed` にして loop 全体を止める。
- 親 issue（`## 子タスク` のチェックリスト）は子に展開し、「（#M のあと）」の依存が CLOSED の子だけを対象にする。子を単体で指定・ラベル付けしても、本文の「親 issue: #P」から同じ依存判定をする。親自体は閉じない（子が全部 CLOSED になったらユーザーが閉じる）。
- 直列で 1 issue ずつ進む（並列は無い。並列の子はコンフリクトで止まりやすいため）。1 巡して何かマージできたら選び直し、依存が解けた子を同じ run で拾う。同じ repo で 2 本目は起動できない（lock）。
- CI の check が無い repo はローカルの `scripts/check` だけを根拠にマージする（`.github/workflows` がある repo では check の登録を上限まで待つ）。`scripts/check` も無い repo はゲート無しになるので、乗せる前に用意する。
- 本体 checkout が default branch 上でクリーンなら、マージのたびに ff で追随させる。別ブランチにいるときは触らない（worktree は常に `origin/<default>` から切るので影響しない）。

## 禁止事項

- このセッションで issue の実装を始めない（実装は worker の役割。手を出すと worktree と競合する）。
- needs-human に切り出された issue を、理由を読まずにラベルだけ外して再投入しない。理由（コメント）を読んでユーザーに判断を仰ぐ。
- `wt loop` を worktree 側のセッションから起動しない（dev 側で起動する）。
