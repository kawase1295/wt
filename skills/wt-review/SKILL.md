---
name: wt-review
description: マージ前レビューのために、自分の worktree ブランチの diff からレビュー用 HTML を subagent で生成し、ブラウザで開いてユーザーの承認を待つ。worktree 側の Claude Code セッションで /wt-merge の前に使う。「/wt-review」「レビューページを作って」のとき使う。
---

# /wt-review — マージ前にレビュー用ページを作って承認を待つ

**worktree 側のセッションで実行する**。cwd が本体 checkout（worktree でない）なら、worktree 側セッションで実行するよう案内して止まる。実行後は**ユーザーの承認を待つ** — 承認を得る前に /wt-merge へ進まない。

## 手順

1. `git status --porcelain` で未コミット変更を確認する。あれば先にコミットする（レビュー対象を確定させるため。/wt-merge と同じ方針）。
2. レビュー対象を求める:

   ```bash
   MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
   BASE="$(git -C "$MAIN" rev-parse HEAD)"
   git log --oneline "$BASE"..HEAD        # 取り込まれるコミット
   git diff "$BASE"...HEAD --stat         # 変更ファイル一覧
   ```

   コミットも diff も無ければ「レビューする変更がありません」と報告して止まる。コミットはあるが diff が空（net-zero）なら、HTML は作らずコミット一覧を報告して承認を仰ぐ。
3. 変更の要約を**自分で**書く（subagent はこのセッションの経緯を知らない）: 何を・なぜ変えたか、主要な設計判断、実行したテストと結果。レビューページの価値の半分はこの要約にある。
4. 出力パスを決める: `<scratchpad>/wt-review-<task>.html`。scratchpad はシステムプロンプト記載のセッション scratchpad ディレクトリ、task はブランチ名から `worktree-` を除いたもの。**パスは固定する** — 再レビュー時に同じファイルへ上書きされ、ブラウザの再読み込みだけで最新化される。
5. HTML 生成を general-purpose subagent に委任する（Agent tool、`run_in_background: false`。diff 本文や HTML を main context に持ち込まないための委任なので、自分で生成しない）。prompt に含めるもの:
   - 出力パス（絶対パス）と worktree のパス（cwd）
   - `BASE` の SHA と diff 取得コマンド（`git diff <BASE>...HEAD`。diff 本文は subagent が自分で取得する）
   - 手順 3 の要約・テスト結果
   - HTML 要件:
     - **local-artifact skill をロードして従う** — Artifact と同一の設計規約（artifact-design 準拠、Geist 優先）で作り、skeleton / テーマトグル / mermaid をローカルで再現する契約。Artifact tool 禁止もそこに含まれる。Write で出力パスに書き、ブラウザで開くのは呼び出し元（手順 6）が行う
     - 構成: ヘッダ（task / branch / base / コミット一覧）→ 変更概要（アーキテクチャ・依存関係・データフローに関わる変更なら mermaid の構成図を添える）→ テスト結果 → ファイル別 diff（追加・削除の色分けと行番号、ファイルごとに `<details>` で折りたたみ可能）
6. ブラウザで開く: `explorer.exe "$(wslpath -w <出力パス>)" || true`（explorer.exe は成功時も非 0 を返すことがあるため失敗扱いしない）。
7. 出力パスと要約を報告してターンを終え、レビューを待つ。「承認なら /wt-merge に進みます。修正指摘はこのまま返信してください」と添える。

## レビュー後

- **指摘があれば**: 修正 → コミット → /wt-review を再実行する（同じパスに上書きされるため、ブラウザは再読み込みだけでよい）。
- **承認されたら**: /wt-merge → /wt-clean に進む。

## 禁止事項

- ユーザーの承認を得る前に /wt-merge を実行しない。自己判断で承認扱いしない。
- レビューページを Artifact tool で外部に publish しない。local ファイルに限る。
