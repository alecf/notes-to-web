import Foundation

/// The stylesheet written to `assets/style.css` on export, and inlined into the
/// in-app preview.
///
/// Kept as a Swift literal rather than a SwiftPM resource: `embedInCode` is not
/// supported by the multi-arch build path used for universal release binaries,
/// and a `.process` resource would need its bundle copied into the .app by hand.
public enum Stylesheet {
    public static let css = #"""
:root {
  color-scheme: light dark;
  --ink: #16181d;
  --ink-soft: #5b6169;
  --bg: #fdfdfc;
  --rule: #e4e2dd;
  --accent: #b4543a;
  --measure: 42rem;
}

@media (prefers-color-scheme: dark) {
  :root {
    --ink: #e8e6e1;
    --ink-soft: #9aa0a8;
    --bg: #16181b;
    --rule: #2c2f34;
    --accent: #e08b6f;
  }
}

* { box-sizing: border-box; }

body {
  margin: 0;
  padding: 4rem 1.5rem 8rem;
  background: var(--bg);
  color: var(--ink);
  font: 400 1.0625rem/1.65 ui-sans-serif, -apple-system, "SF Pro Text", system-ui, sans-serif;
  -webkit-text-size-adjust: 100%;
}

.note {
  max-width: var(--measure);
  margin: 0 auto;
}

h1, h2, h3 {
  line-height: 1.25;
  text-wrap: balance;
  margin: 2.5rem 0 0.75rem;
  font-weight: 640;
  letter-spacing: -0.015em;
}

h1 {
  font-size: clamp(1.75rem, 1.2rem + 2.2vw, 2.5rem);
  margin-top: 0;
  padding-bottom: 1.25rem;
  border-bottom: 1px solid var(--rule);
}

h2 { font-size: 1.375rem; }
h3 { font-size: 1.125rem; color: var(--ink-soft); }

p { margin: 0 0 1rem; }

a { color: var(--accent); text-underline-offset: 0.15em; }

ul, ol { margin: 0 0 1rem; padding-left: 1.5rem; }
li { margin-bottom: 0.35rem; }
li[style*="--indent"] { margin-left: calc(var(--indent, 0) * 1.5rem); }

ul.dashed { list-style: none; padding-left: 1.5rem; }
ul.dashed > li::before {
  content: "–";
  position: absolute;
  margin-left: -1.25rem;
  color: var(--ink-soft);
}

ul.checklist { list-style: none; padding-left: 0; }
ul.checklist > li {
  display: flex;
  gap: 0.6rem;
  align-items: baseline;
}
ul.checklist > li.done > span {
  text-decoration: line-through;
  color: var(--ink-soft);
}
ul.checklist input { margin: 0; accent-color: var(--accent); }

pre {
  overflow-x: auto;
  padding: 1rem;
  border-radius: 0.5rem;
  background: color-mix(in srgb, var(--ink) 6%, transparent);
}

pre, code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; }

/* Attachments ------------------------------------------------------------- */

figure.attachment {
  margin: 1.75rem 0;
}

figure.attachment video,
figure.attachment img {
  display: block;
  width: 100%;
  height: auto;
  max-height: 78vh;
  border-radius: 0.75rem;
  background: #000;
}

figure.attachment img { background: transparent; }

figure.attachment audio { width: 100%; }

figure.attachment.file a,
figure.attachment.link a,
figure.attachment.missing span,
figure.attachment.placeholder span {
  display: flex;
  gap: 0.6rem;
  align-items: baseline;
  padding: 0.85rem 1rem;
  border: 1px solid var(--rule);
  border-radius: 0.6rem;
  text-decoration: none;
  color: var(--ink);
}

figure.attachment small { color: var(--ink-soft); }

figure.attachment.missing span,
figure.attachment.placeholder span {
  color: var(--ink-soft);
  border-style: dashed;
}

@media (max-width: 34rem) {
  body { padding: 2.5rem 1.1rem 5rem; }
}
"""#
}
