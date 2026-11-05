import Foundation

/// Reader (Page ▸ Show Reader, ⇧⌘R): the page's main text alone, over the page, in plain type.
///
/// - The article is `<article>`, else `<main>`, else the block holding the most paragraph text.
/// - Scripts, forms, navigation, asides and sharing widgets inside it are left out.
/// - Run again (or Esc) to take it away; the page underneath is untouched.
enum CanvasReader {
    static let script = """
    (() => {
      const id = '__folioReader';
      const old = document.getElementById(id);
      if (old) { old.remove(); document.documentElement.style.overflow = ''; return 'off'; }
      const textOf = el => [...el.querySelectorAll('p')].reduce((n, p) => n + p.innerText.length, 0);
      let best = document.querySelector('article') || document.querySelector('main');
      if (!best || textOf(best) < 500) {
        let score = 0;
        document.querySelectorAll('div, section, article, main').forEach(el => {
          const direct = [...el.children].filter(c => c.tagName === 'P').reduce((n, p) => n + p.innerText.length, 0);
          if (direct > score) { score = direct; best = el; }
        });
      }
      if (!best) return 'none';
      const copy = best.cloneNode(true);
      copy.querySelectorAll('script, style, noscript, iframe, form, button, nav, aside, footer, header, svg, [role=navigation], [aria-hidden=true], [class*=share], [class*=social], [class*=related], [class*=newsletter], [class*=promo], [class*=advert]').forEach(e => e.remove());
      copy.querySelectorAll('*').forEach(e => { e.removeAttribute('style'); e.removeAttribute('class'); e.removeAttribute('width'); e.removeAttribute('height'); });
      const title = (document.querySelector('h1') || {}).innerText || document.title;
      const host = location.hostname.replace(/^www\\./, '');
      const overlay = document.createElement('div');
      overlay.id = id;
      const shadow = overlay.attachShadow({ mode: 'open' });
      shadow.innerHTML = `<style>
        :host { all: initial; position: fixed; inset: 0; z-index: 2147483647; overflow: auto;
          background: #faf8f4; color: #1d1d1f; }
        @media (prefers-color-scheme: dark) { :host { background: #1e1e1f; color: #e8e6e3; } a { color: #8ab4f8; } }
        .page { max-width: 680px; margin: 0 auto; padding: 56px 28px 96px;
          font: 19px/1.6 'New York', ui-serif, Georgia, serif; }
        .host { font: 600 12px -apple-system, system-ui; letter-spacing: .04em; text-transform: uppercase; opacity: .55; }
        h1.title { font: 700 34px/1.2 -apple-system, system-ui; margin: 8px 0 28px; }
        img, video, figure { max-width: 100%; height: auto; border-radius: 6px; }
        figure { margin: 24px 0; } figcaption { font-size: 14px; opacity: .65; }
        pre, code { font: 15px ui-monospace, Menlo, monospace; white-space: pre-wrap; }
        blockquote { margin: 0; padding-left: 18px; border-left: 3px solid currentColor; opacity: .8; }
        a { color: #0a64d6; }
        .close { position: fixed; top: 14px; right: 18px; font: 13px -apple-system, system-ui; opacity: .6;
          cursor: pointer; border: 0; background: none; color: inherit; }
      </style>
      <button class="close" title="Close Reader">Close Reader</button>
      <div class="page"><div class="host"></div><h1 class="title"></h1><div class="body"></div></div>`;
      shadow.querySelector('.host').textContent = host;
      shadow.querySelector('.title').textContent = title;
      const firstHeading = copy.querySelector('h1');
      if (firstHeading && firstHeading.innerText.trim() === title.trim()) firstHeading.remove();
      shadow.querySelector('.body').appendChild(copy);
      const close = () => { overlay.remove(); document.documentElement.style.overflow = ''; };
      shadow.querySelector('.close').addEventListener('click', close);
      document.addEventListener('keydown', function esc(e) {
        if (e.key === 'Escape' && document.getElementById(id)) { close(); document.removeEventListener('keydown', esc, true); }
      }, true);
      document.documentElement.style.overflow = 'hidden';
      document.documentElement.appendChild(overlay);
      return 'on';
    })()
    """
}
