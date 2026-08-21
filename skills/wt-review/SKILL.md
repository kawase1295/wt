---
name: wt-review
description: マージ前レビューのために、自分の worktree ブランチの diff から同梱テンプレート + render.py でレビュー用 HTML を subagent に生成させ、ブラウザで開いてユーザーの承認を待つ。worktree 側の Claude Code セッションで /wt-merge の前に使う。「/wt-review」「レビューページを作って」のとき使う。
---

# /wt-review — マージ前にレビュー用ページを作って承認を待つ

**worktree 側のセッションで実行する**。cwd が本体 checkout（worktree でない）なら、worktree 側セッションで実行するよう案内して止まる。実行後は**ユーザーの承認を待つ** — 承認を得る前に /wt-merge へ進まない。

ページの体裁は `assets/` の固定資産（テンプレート + `render.py`）が持つ。**HTML をゼロから書かせない。**

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
3. 変更の要約を**自分で**書く（subagent はこのセッションの経緯を知らない）: 何を・なぜ変えたか、主要な設計判断、検討して採らなかった案、実行したテストと結果、未検証で残っていること。レビューページの価値の半分はこの要約にある。**日本語の素文でよい** — HTML に起こすのは subagent の仕事。
4. 出力パスを決める: `<scratchpad>/wt-review-<task>.html`。scratchpad はシステムプロンプト記載のセッション scratchpad ディレクトリ、task はブランチ名から `worktree-` を除いたもの。**パスは固定する** — 再レビュー時に同じファイルへ上書きされ、ブラウザの再読み込みだけで最新化される。
5. 生成資産の場所を求める。skill は plugin 経由と `install.sh` 経由で置き場所が違うので、存在する方を採る:

   ```bash
   ASSETS=""
   for d in \
     ${CLAUDE_PLUGIN_ROOT:+"$CLAUDE_PLUGIN_ROOT/skills/wt-review/assets"} \
     "$(dirname "$(command -v wt || echo /x)")/../skills/wt-review/assets" \
     "$HOME/.claude/skills/wt-review/assets"
   do
     [ -f "$d/render.py" ] && ASSETS="$(cd "$d" && pwd)" && break
   done
   echo "${ASSETS:-NOT_FOUND}"
   ```

   `NOT_FOUND` なら「レビューページの生成資産が見つからない。`install.sh` を再実行するか plugin を入れ直してください」と報告して止まる。**assets 無しで HTML を自作して代替しない。**
6. HTML 生成を general-purpose subagent に委任する（Agent tool、`run_in_background: false`）。diff 本文と HTML を main context に持ち込まないための委任なので、自分で生成しない。prompt に含めるもの:
   - worktree のパス（cwd）、`BASE` の SHA、`ASSETS` の絶対パス、出力パス（絶対パス）、scratchpad ディレクトリ
   - 手順 3 で書いた要約とテスト結果（**材料**。これを HTML 断片に起こすのが subagent の仕事）
   - 手順:
     1. `git diff <BASE>...HEAD > <scratchpad>/net.diff`
     2. `<ASSETS>/README.md` を読む（プレースホルダー契約と、断片で使えるクラス一覧）
     3. `<scratchpad>/summary.html` と `<scratchpad>/tests.html` を書く。**README に載っているクラスだけを使う**（独自クラスはスタイルが当たらない）。`<h2>` の節見出しは書かない（テンプレートが持っている）。アーキテクチャ・依存関係・データフローに関わる変更なら `<pre class="mermaid">` の図を添える
     4. 実行する:

        ```bash
        python3 "<ASSETS>/render.py" \
          --diff "<scratchpad>/net.diff" --out "<出力パス>" \
          --title "<タスク名>" --base "<BASE>" \
          --summary "<scratchpad>/summary.html" --tests "<scratchpad>/tests.html"
        ```

        巨大な生成物ファイル（lock ファイル等）が邪魔なら `--collapse <path>` を足す。既定では増減の合計が 200 行を超えるファイルが折りたたまれる
     5. 返すのは `render.py` の stdout（files / 増減行数 / ファイルごとの開閉 / バイト数）と、断片で強調した点の一行要約だけ。**HTML 本文や diff 本文は返さない**
   - 禁止事項: テンプレートを書き換えない / HTML を自作して `render.py` を迂回しない / Artifact tool で publish しない / `local-artifact` skill をロードしない（skeleton・テーマトグル・mermaid はテンプレートが内包しているため不要）
7. ブラウザで開く: `wt browse <出力パス>`。プラットフォームごとの開き方（WSL の `explorer.exe` / macOS の `open` / Linux の `xdg-open`）は `wt` が吸収する。開く手段が無い環境では失敗するので、そのときはパスを報告してユーザーに開いてもらう。
8. 出力パスと要約、`render.py` の統計を報告してターンを終え、レビューを待つ。「承認なら /wt-merge に進みます。修正指摘はこのまま返信してください」と添える。

## レビュー後

- **指摘があれば**: 修正 → コミット → /wt-review を再実行する（同じパスに上書きされるため、ブラウザは再読み込みだけでよい）。
- **承認されたら**: /wt-merge → /wt-clean に進む。

## 禁止事項

- ユーザーの承認を得る前に /wt-merge を実行しない。自己判断で承認扱いしない。
- **レビューページを Artifact tool で publish しない。** 業務コードの diff を claude.ai へ送ることになる。ローカルファイルのまま `wt browse` で開く。
- テンプレート（`assets/wt-review-template.html`）をレビューのたびに書き換えない。体裁の変更は repo への変更として別途行う。
