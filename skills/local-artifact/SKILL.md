---
name: local-artifact
description: Artifact と同一の設計規約（artifact-design）で HTML ページを作り、claude.ai に publish せずローカルファイルとして公開してブラウザで開く契約。レビューページ・構成図・可視化などで「Artifact 相当をローカルで」のとき使う。Artifact ランタイムが提供する skeleton / CSS リセット / テーマトグル / mermaid 描画を自前で埋め込む。
---

# local-artifact — Artifact 相当のページをローカルで公開する

業務コードや秘匿情報を含むページは Artifact tool で claude.ai にホストしない。代わりに**設計は Artifact と同一の規約**で作り、Artifact ランタイムが提供する機能だけをローカルで再現する。設計と公開を分離する: 設計は artifact-design に従い、公開だけがローカル専用の動きになる。

## 手順

1. artifact-design skill をロードし、その指針（treatment の較正・タイポグラフィ・色・情報設計・クリシェ回避）に従ってページを設計する。デザインシステムの指定があれば（`~/.claude/DESIGN.md` の Geist 等）そちらを優先する。
2. Artifact と違い自動ラップが無いので、**完全な HTML 文書**として書く。下のランタイム再現テンプレートを土台にする。
3. 外部リソース参照は禁止（CDN・webfont・fetch）。唯一の例外は同ディレクトリに同梱する `./mermaid.min.js`。
4. 出力先は呼び出し元の指定パス。指定が無ければ scratchpad に書く。
5. 呼び出し元が開く手はずになっていなければ、ブラウザで開く: `explorer.exe "$(wslpath -w <path>)" || true`（explorer.exe は成功時も非 0 を返すことがあるため失敗扱いしない。wslview は未導入）。

## ランタイム再現テンプレート

Artifact viewer が注入する skeleton / 最小リセット / テーマトグルを再現する。テーマは `prefers-color-scheme` を既定信号とし、トグルが root に `data-theme` を刻印して**両方向に**上書きする — artifact-design のテーマ指針がそのまま効く形になる。

```html
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>…</title>
<style>
  /* Artifact 相当の最小リセット */
  *, *::before, *::after { box-sizing: border-box; }
  body { margin: 0; -webkit-font-smoothing: antialiased; }
  img, svg, video { max-width: 100%; height: auto; }
  /* トークン定義の規約: light を :root に、dark を
     @media (prefers-color-scheme: dark) と :root[data-theme="dark"] の両方に置き、
     :root[data-theme="light"] で light を再宣言して data-theme が常に勝つようにする */
</style>
</head>
<body>
  <!-- content。テーマ切替ボタンを 1 つ置く（id は "theme-toggle" 固定。配置・見た目は設計に従う） -->
  <script>
    const root = document.documentElement;
    const effectiveTheme = () =>
      root.dataset.theme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
    document.getElementById('theme-toggle').addEventListener('click', () => {
      root.dataset.theme = effectiveTheme() === 'dark' ? 'light' : 'dark';
      document.dispatchEvent(new CustomEvent('themechange'));
    });
  </script>
</body>
</html>
```

## mermaid（構成図・フロー図・シーケンス図）

Artifact は `<pre class="mermaid">` をネイティブ描画するが、ローカルでは lib を同梱して再現する。

1. lib をキャッシュから出力ディレクトリの隣に置く（キャッシュに無ければ 1 度だけ取得する）:

   ```bash
   mkdir -p ~/.cache/wt
   [ -f ~/.cache/wt/mermaid.min.js ] ||
     curl -fsSL https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js -o ~/.cache/wt/mermaid.min.js
   cp ~/.cache/wt/mermaid.min.js "<出力ディレクトリ>/"
   ```

   キャッシュ後は再取得しないため lib のバージョンは実質固定される。更新したいときは `~/.cache/wt/mermaid.min.js` を削除して再取得する。

2. ページ側（Artifact と同じ `<pre class="mermaid">` 記法）:

   ```html
   <pre class="mermaid">
   graph LR
     A[client] --> B[api]
   </pre>
   <script src="./mermaid.min.js"></script>
   <script>
    // テーマと連動して再描画する。ソースを保持し、themechange のたびに描画し直す。
    // mermaid.run の並走はレンダリングを壊すため、promise チェーンで直列化する
    const diagrams = [...document.querySelectorAll('pre.mermaid')];
    const sources = diagrams.map(el => el.textContent);
    let rendering = Promise.resolve();
    function renderDiagrams() {
      rendering = rendering.then(async () => {
        mermaid.initialize({ startOnLoad: false,
          theme: effectiveTheme() === 'dark' ? 'dark' : 'default' });
        diagrams.forEach((el, i) => {
          el.removeAttribute('data-processed');
          el.textContent = sources[i];
        });
        await mermaid.run({ nodes: diagrams });
      }).catch(console.error);
      return rendering;
    }
    renderDiagrams();
    document.addEventListener('themechange', renderDiagrams);
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
      if (!root.dataset.theme) renderDiagrams();
    });
   </script>
   ```

   注意点:
   - `script src` は**相対パス必須** — ページは `\\wsl.localhost\...` 経由で開かれるため、絶対 POSIX パス（`/home/...`）は解決されない。
   - このブロックはテンプレートの `effectiveTheme` / `root` に依存するため、**トグルスクリプトより後**に置く。
   - ノードラベル内の改行は `&lt;br/&gt;` とエスケープして書く。生の `<br/>` は HTML として parse され、`textContent` でのソース捕捉時に脱落する。
3. lib の取得も同梱もできない場合（オフライン等）は、図を inline SVG で描くか、mermaid ソースをコードブロックで表示して「未描画」と注記する。黙って図を落とさない。

## 禁止事項

- Artifact tool での publish（claude.ai への外部ホスト）。
- CDN・webfont 等の外部参照（オンライン前提のページにしない）。
