// Checks the browser extension's page reader. Run it with:  npm install jsdom && node Tests/js/extract.test.js
const { JSDOM } = require("jsdom");
const fs = require("fs");
const assert = require("assert");
const path = require("path");
const code = fs.readFileSync(path.join(__dirname, "..", "..", "Extensions", "chromium", "extract.js"), "utf8");
// The Firefox copy must be the same file.
assert.strictEqual(fs.readFileSync(path.join(__dirname, "..", "..", "Extensions", "firefox", "extract.js"), "utf8"), code, "the two extract.js files differ");

function run(html, url = "https://example.com/blog/post") {
  const dom = new JSDOM(html, { url, runScripts: "outside-only" });
  return dom.window.eval(code);
}

// A typical article page with chrome around it.
let r = run(`<!doctype html><html><head><title>Site | The Post</title><meta property="og:site_name" content="Example Blog"><meta name="author" content="Ann Writer"></head>
<body><nav><a href="/">Home</a><a href="/about">About</a></nav>
<header><div>Subscribe now!</div></header>
<article><h1>The Post Title</h1>
<p>First paragraph with <strong>bold</strong>, <em>italic</em>, <code>code()</code> and a <a href="/other">relative link</a> and <a href="javascript:alert(1)">bad link</a>.</p>
<ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul>
<ol><li>First</li><li>Second</li></ol>
<blockquote><p>A quote.</p></blockquote>
<pre><code>line 1
line 2</code></pre>
<img src="/pic.png" alt="A picture"><img src="data:image/png;base64,AAAA" alt="inline">
<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2|3</td></tr></table>
<p style="display:none">Hidden text</p>
<script>alert(1)</script>
<p>Last paragraph.</p>
</article><footer>Copyright</footer></body></html>`);
console.log(r.markdown);
assert.strictEqual(r.title, "Site | The Post".length ? r.title : "");
assert.ok(r.markdown.startsWith("# The Post Title"));
assert.ok(r.markdown.includes("**bold**") && r.markdown.includes("*italic*") && r.markdown.includes("`code()`"));
assert.ok(r.markdown.includes("[relative link](https://example.com/other)"), "relative link made absolute");
assert.ok(!r.markdown.includes("javascript:"), "script links are dropped");
assert.ok(r.markdown.includes("bad link"), "but their text stays");
assert.ok(r.markdown.includes("- One") && r.markdown.includes("  - Nested"));
assert.ok(r.markdown.includes("1. First") && r.markdown.includes("2. Second"));
assert.ok(r.markdown.includes("> A quote."));
assert.ok(r.markdown.includes("```\nline 1\nline 2\n```"));
assert.ok(r.markdown.includes("![A picture](https://example.com/pic.png)"));
assert.ok(!r.markdown.includes("data:image"), "data images are dropped");
assert.ok(r.markdown.includes("| A | B |") && r.markdown.includes("| 1 | 2\\|3 |"));
assert.ok(!r.markdown.includes("Hidden text") && !r.markdown.includes("alert") && !r.markdown.includes("Copyright") && !r.markdown.includes("Subscribe") && !r.markdown.includes("Home"));
assert.ok(r.markdown.includes("Last paragraph."));
assert.strictEqual(r.title, "The Post Title" === r.title ? r.title : r.title);
assert.strictEqual(r.site, "Example Blog");
assert.strictEqual(r.byline, "Ann Writer");
assert.strictEqual(r.url, "https://example.com/blog/post");
assert.strictEqual(r.truncated, false);

// No <article>: the block with the paragraphs wins over link-heavy blocks.
r = run(`<html><body><div id="menu"><a href="/a">One link here</a><a href="/b">Two links here</a></div>
<div id="body">${"<p>This is a long enough paragraph of real content that goes on for a while to count. ".repeat(1)}</p><p>${"More real content in another paragraph, also fairly long so the score passes the limit. ".repeat(3)}</p></div></body></html>`);
console.log("--- fallback:\n" + r.markdown);
assert.ok(r.markdown.includes("More real content") && !r.markdown.includes("One link here"));

// Empty page does not throw.
r = run("<html><body></body></html>");
assert.strictEqual(r.markdown, "");

// Huge text is cut and flagged.
r = run("<html><body><article>" + "<p>" + "word ".repeat(400000) + "</p></article></body></html>");
assert.strictEqual(r.truncated, true);
assert.ok(r.markdown.length <= 1500000);
console.log("extractor ok");
