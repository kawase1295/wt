# `/wt-review` レビューページの生成資産

`/wt-review` が作るマージ前レビューページの**固定資産**。CSS・JS・骨格・節見出しは
`wt-review-template.html` が持ち、`render.py` が毎回変わる部分だけを差し込む。

呼び出し側（`../SKILL.md`）が書くのは**変更概要とテスト結果の HTML 断片 2 枚だけ**。
ページの体裁を毎回考え直す必要はない。

## ファイル

| ファイル | 内容 |
| --- | --- |
| `wt-review-template.html` | テンプレート。`<style>` 20KB と `<script>`（テーマトグル + mermaid 描画 + 承認ボタン）を内包する |
| `render.py` | net.diff をパースして diff HTML を組み立て、テンプレートに差し込む。標準ライブラリのみ |
| `sample-net.diff` | 動作確認用の diff。架空のアプリ `recipe-box` に印刷用ビューを足した 4 ファイル +342/-3 |
| `sample-summary.html` | 動作確認用の要約断片。使えるクラスの見本も兼ねる |

サンプルは**架空の題材で作る**。この repo は公開しているので、実在プロジェクトの
diff や要約を置かないこと。作り直すときは一時 git repo に架空のコードをコミットして
`git diff` を取る。テストが構造を前提にしているので、次を満たすこと — 4 ファイル程度、
うち 1 つだけが増減合計 200 行超（折りたたみ閾値の検証用）、最小のファイルが 10 行超。
実数を変えたら `tests/wt_test.sh` の期待値も更新する。

## `render.py`

```
render.py --diff <net.diff> --out <out.html> --title <text> --summary <summary.html>
          [--tests <tests.html>]         # 省略すると「テスト結果」節ごと出さない
          [--template <path>]            # 既定: スクリプトと同ディレクトリのテンプレート
          [--base <sha>] [--head <ref>]  # メタ情報とコミット一覧を git から作る
          [--open <path>]...             # このファイルを開いた状態にする
          [--collapse <path>]...         # このファイルを折りたたむ
          [--collapse-threshold <n>]     # 既定 200。増減の合計がこれを超えたら折りたたむ
          [--no-mermaid]
```

- **cwd が git の作業ツリーであること**を前提にする（`--base` を渡したときだけ `git` を叩く）。
  `--base` を省くと Branch / Base SHA のセルとコミット一覧の節が出ない
- 折りたたみは **明示指定 > 行数閾値**。`--open` と `--collapse` の両方に同じパスを渡したら `--open` が勝つ
- diff に無いパスを `--open` / `--collapse` に渡すと警告する（タイポ検知）
- 埋まっていないプレースホルダーが残ったら**書き込まずに終了する**（exit 2）
- 終了時に files / +行 / -行 / ファイルごとの開閉 / 出力バイト数を stdout に出す

### mermaid

`--summary` / `--tests` の中身に `class="mermaid"` が含まれるときだけ、出力ディレクトリへ
`mermaid.min.js` を置き、描画スクリプトを有効にする。`~/.cache/wt/mermaid.min.js` に
無ければ `curl` で取得してキャッシュする（`../../local-artifact/SKILL.md` と同じ手順）。
取得できなければ警告を出して描画スクリプトを落とす（図はソースのまま表示される）。

### 承認ボタン

テンプレートは末尾に「承認」節（`#approve`）を持っている。`render.py` は差し込みも
出し分けもしない — 常に `hidden` で出力し、`hidden` を外すのはページ内の script。
条件は「`http(s)` で開かれていて `?token=...` が付いている」こと、つまり
`wt serve` の配信経由で開いたときだけ出る。`file://` では投げる先が無いので
節ごと隠れたままになる（承認はセッションに戻って入力する）。

押すと same-origin の `POST /approve`（token 付き）になり、配信サーバ
（repo ルートの `wt-review-serve.py`）が `herdr agent prompt claude-<task>` で
「承認します。/wt-merge に進んでください」を worktree セッションへ投入して終了する。
承認は**ユーザーの直接入力**としてセッションに届くので、レビューゲートの原則は保たれる。

### 動作確認

```sh
cd skills/wt-review/assets
python3 render.py --diff sample-net.diff --out /tmp/sample.html \
  --title "サンプル" --summary sample-summary.html
```

`files=4 +342 -3` と出れば期待どおり。回帰テストは `tests/wt_test.sh` にある。

## プレースホルダー契約

テンプレートに置いてあるのは次の 8 個。`render.py` は**全部を必ず消費する**
（残っていたらエラーで止まる）。

| プレースホルダー | 埋める人 | 中身 |
| --- | --- | --- |
| `<!--TITLE-->` | render.py | `--title`。`<title>` と `<h1>` の 2 か所に入る |
| `<!--BRANCH-->` | render.py | ブランチ名。sticky な topbar に出る |
| `<!--META-->` | render.py | meta-grid のセル（Branch / Base SHA / Net diff / Lines） |
| `<!--COMMITS-->` | render.py | `git log <base>..<head>` のコミット行（古い順） |
| `<!--SUMMARY-->` | **呼び出し側** | 変更概要。`--summary` の HTML 断片をそのまま差し込む |
| `<!--TESTS-->` | **呼び出し側** | テスト結果。`--tests` の HTML 断片 |
| `<!--FILE_SUMMARY-->` | render.py | ファイル別の増減バー |
| `<!--DIFF_SECTION-->` | render.py | ファイル別 diff（`<details>`） |

節ごと落とすために、3 か所が `<!--NAME_BEGIN-->` / `<!--NAME_END-->` で囲われている。
`render.py` が中身だけ残すか、領域を丸ごと落とす。

| 領域 | 落ちる条件 |
| --- | --- |
| `COMMITS` | `--base` 省略、または `<base>..<head>` にコミットが無い |
| `TESTS` | `--tests` 省略 |
| `MERMAID` | 断片に `class="mermaid"` が無い / `--no-mermaid` / `mermaid.min.js` を用意できない |

節見出し（`<h2>`）はテンプレート側が持つ。断片は**中身だけ**を書く。

## summary / tests 断片で使えるクラス

CSS はテンプレートが持っているので、**独自クラスを書くとスタイルが当たらない**。
下記から選ぶ。生の `<p>` `<h3>` `<ul>` `<strong>` `<code>` `<a>` はそのまま使える。

### 器とレイアウト

| クラス | 用途 |
| --- | --- |
| `stack` / `stack-lg` | 縦積み。gap 16px / 24px。断片の一番外側はこれで包む |
| `grid-2` | 2 カラム。狭い画面では 1 カラムに落ちる |
| `card` / `card-compact` | 枠付きのカード。padding 24px / 16px |
| `filecard-head` + `filecard-path` | カード先頭のファイル名行（右端にチップを置ける） |

### 文字と記号

| クラス | 用途 |
| --- | --- |
| `lede` | 節の頭に置く導入文。少し大きい |
| `mono` | 等幅にする（`code` は指定不要） |
| `bullets` | 箇条書き（`<ul class="bullets">`）。`strong` が濃く出る |
| `count-add` / `count-del` | `+12` / `-3` の色分け |

### チップ

`<span class="chip">…</span>` が基本形。バリアントを足す: `chip-final`（青、採用・最終）、
`chip-done`（緑、実施済み）、`chip-todo`（赤、未実施）、`chip-warn`（黄、注意）。
先頭に丸を出したいときは `<span class="chip chip-done"><span class="dot"></span>実施</span>`。

### 注意書き

```html
<div class="callout callout-amber">
  <p class="callout-title">見出し</p>
  <p>本文</p>
</div>
```

`callout-amber`（注意）/ `callout-blue`（補足・利点）/ `callout-red`（危険）。

### 検討の経緯

```html
<ol class="options">
  <li class="option">
    <p class="option-name">案 1 — …</p>
    <span class="chip">取りやめ</span>
    <p class="option-why">却下理由</p>
  </li>
  <li class="option option-adopted">
    <p class="option-name">案 2 — …</p>
    <span class="chip chip-final">採用</span>
    <p class="option-why">採用理由</p>
  </li>
</ol>
```

### 図（mermaid）

```html
<figure style="margin:0;">
  <pre class="mermaid">
flowchart TD
  A["入口"] --> B["出口"]
  </pre>
  <figcaption class="figcaption">図の説明</figcaption>
</figure>
```

mermaid のラベル内で改行したいときは `&lt;br/&gt;` と書く（HTML に直接埋めるため）。
ASCII 図をそのまま出すなら `<pre class="diagram">`。

### テスト結果向け

```html
<div class="test-stats">
  <div class="test-stat test-stat-done"><span class="num">2</span><span class="lbl">実施</span></div>
  <div class="test-stat test-stat-todo"><span class="num">3</span><span class="lbl">未実施</span></div>
</div>

<div class="stack">
  <div class="panel-todo">
    <p class="panel-heading"><span class="chip chip-todo"><span class="dot"></span>未実施</span>この 3 点は検証していません</p>
    <p class="panel-sub">マージ判断の前提にしてください。</p>
    <ul class="test-list">
      <li class="test-item">
        <span class="chip chip-todo">未実施</span>
        <div>
          <p class="test-item-title">見出し</p>
          <p class="test-item-body">詳細</p>
        </div>
      </li>
    </ul>
  </div>
  <div class="panel-done"><!-- 同じ構造で chip-done / test-stat-done を使う --></div>
</div>
```

`panel-todo` は赤系、`panel-done` は緑系の枠になる。

## なぜ資産化したか

以前は `/wt-review` が毎回 subagent にページ HTML をゼロから書かせていた。
実測で **8 分・約 10 万トークン**かかっていた。

| 実行 | 所要 | subagent_tokens | tool_uses |
| --- | --- | --- | --- |
| 1 回目 | 7分32秒 | 86,501 | 9 |
| 2 回目 | 8分16秒 | 101,943 | 19 |

tool 回数が倍でも時間は 10% 増しかない。**所要時間はトークン量にほぼ比例する**
（191 / 205 tokens/秒）。特定処理の待ちではなく単純に生成量の問題だった。

最終成果物 123,709 文字のうち subagent が手で書いたのは 29%（41,189 文字）で、
残りは同じ subagent が書いた `render.py` が diff から機械生成していた。
つまり無駄はテンプレートを毎回書き直していたことに集約される。

| 区分 | 文字数 | 割合 | 資産化後 |
| --- | --- | --- | --- |
| `<style>` CSS | 19,225 | 53% | 固定 |
| `<script>` JS | 1,226 | 3% | 固定 |
| 本文 HTML | 15,665 | 43% | 骨格は固定、中身だけ差し込む |

手で書く量は要約とテスト結果だけになる（約 11,000 文字）。

## 注意点

- **CSS と JS は触らない。** artifact-design / Geist 準拠で書かれており、`data-theme` と
  `prefers-color-scheme` の両対応も入っている。そのまま使えば規約を満たす
- 見た目が毎回同じになる。subagent の裁量だった頃は実行ごとにデザインが変わっていた。統一は利点
- **Artifact tool で publish しない。** ローカルファイルのまま `wt browse <path>` で開く（`../SKILL.md` の禁止事項）
- トークン換算は CJK 1 文字 = 1 トークン、ASCII 4 文字 = 1 トークンの粗い近似
