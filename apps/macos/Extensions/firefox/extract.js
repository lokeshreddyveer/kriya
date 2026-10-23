// Runs in the page, only when you choose "Save Page to Kriya" from the right-click menu or the button, and only in that tab.
// It reads the main text of the page, turns it into Markdown, and returns it. It sends nothing anywhere itself and loads no
// code. The result goes to the Kriya app on this Mac through the browser's native-messaging connection.
(() => {
  const LIMIT = 1500000;
  const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "IFRAME", "OBJECT", "EMBED", "SVG", "CANVAS", "FORM", "BUTTON",
    "INPUT", "SELECT", "TEXTAREA", "NAV", "FOOTER", "ASIDE", "DIALOG", "AUDIO", "VIDEO", "HEAD"]);

  const base = document.baseURI;

  function hidden(el) {
    if (el.hidden || el.getAttribute("aria-hidden") === "true") return true;
    try {
      const style = getComputedStyle(el);
      return style.display === "none" || style.visibility === "hidden";
    } catch (e) { return false; }
  }

  function textOf(el) { return (el.textContent || "").replace(/\s+/g, " ").trim(); }

  // The part of the page that is the article: <article> or <main> with the most text, else the block with the most paragraph
  // text that is not mostly links, else the body.
  function findMain() {
    const named = [...document.querySelectorAll("article, main, [role=main]")].filter((el) => !hidden(el));
    if (named.length) return named.reduce((best, el) => (textOf(el).length > textOf(best).length ? el : best));
    let best = null, bestScore = 0;
    for (const el of document.querySelectorAll("div, section")) {
      if (hidden(el)) continue;
      let paragraphs = 0;
      for (const child of el.children) if (child.tagName === "P") paragraphs += textOf(child).length;
      const links = [...el.querySelectorAll("a")].reduce((n, a) => n + textOf(a).length, 0);
      const score = paragraphs - links * 0.5;
      if (score > bestScore) { best = el; bestScore = score; }
    }
    return best && bestScore > 200 ? best : document.body;
  }

  function absolute(href) {
    try {
      const url = new URL(href, base);
      return url.protocol === "http:" || url.protocol === "https:" ? url.href : null;
    } catch (e) { return null; }
  }

  function inline(node) {
    let out = "";
    for (const child of node.childNodes) {
      if (child.nodeType === 3) { out += child.nodeValue.replace(/\s+/g, " "); continue; }
      if (child.nodeType !== 1 || SKIP.has(child.tagName.toUpperCase()) || hidden(child)) continue;
      const tag = child.tagName.toLowerCase();
      const inner = () => inline(child);
      if (tag === "br") out += "\n";
      else if (tag === "strong" || tag === "b") { const t = inner().trim(); if (t) out += "**" + t + "**"; }
      else if (tag === "em" || tag === "i") { const t = inner().trim(); if (t) out += "*" + t + "*"; }
      else if (tag === "code") { const t = textOf(child); if (t) out += "`" + t.replace(/`/g, "'") + "`"; }
      else if (tag === "a") {
        const t = inner().trim();
        const href = absolute(child.getAttribute("href") || "");
        out += href && t ? "[" + t + "](" + href + ")" : t;
      } else if (tag === "img") {
        const alt = (child.getAttribute("alt") || "").trim();
        const src = absolute(child.getAttribute("src") || "");
        if (src && alt) out += "![" + alt + "](" + src + ")";
      } else out += inner();
    }
    return out;
  }

  function list(node, depth) {
    const ordered = node.tagName === "OL";
    let n = 0, out = "";
    for (const item of node.children) {
      if (item.tagName !== "LI" || hidden(item)) continue;
      n += 1;
      const mark = ordered ? n + ". " : "- ";
      const pad = "  ".repeat(depth);
      let text = "", nested = "";
      for (const child of item.childNodes) {
        if (child.nodeType === 1 && (child.tagName === "UL" || child.tagName === "OL")) nested += list(child, depth + 1);
        else if (child.nodeType === 1 && /^(P|DIV)$/.test(child.tagName)) text += " " + inline(child).trim();
        else text += child.nodeType === 3 ? child.nodeValue.replace(/\s+/g, " ") : child.nodeType === 1 && !SKIP.has(child.tagName) ? inline({ childNodes: [child] }) : "";
      }
      out += pad + mark + text.trim() + "\n" + nested;
    }
    return out;
  }

  function table(node) {
    const rows = [...node.querySelectorAll("tr")].map((tr) => [...tr.children].map((c) => textOf(c).replace(/\|/g, "\\|")));
    if (!rows.length) return "";
    const width = Math.max(...rows.map((r) => r.length));
    const pad = (r) => r.concat(Array(width - r.length).fill(""));
    const lines = rows.map((r) => "| " + pad(r).join(" | ") + " |");
    lines.splice(1, 0, "|" + Array(width).fill(" --- ").join("|") + "|");
    return lines.join("\n") + "\n\n";
  }

  function blocks(node) {
    let out = "";
    for (const child of node.childNodes) {
      if (child.nodeType === 3) {
        const t = child.nodeValue.replace(/\s+/g, " ").trim();
        if (t) out += t + "\n\n";
        continue;
      }
      if (child.nodeType !== 1 || SKIP.has(child.tagName.toUpperCase()) || hidden(child)) continue;
      const tag = child.tagName.toLowerCase();
      if (/^h[1-6]$/.test(tag)) { const t = inline(child).trim(); if (t) out += "#".repeat(Number(tag[1])) + " " + t + "\n\n"; }
      else if (tag === "p") { const t = inline(child).trim(); if (t) out += t + "\n\n"; }
      else if (tag === "ul" || tag === "ol") out += list(child, 0) + "\n";
      else if (tag === "blockquote") { const t = blocks(child).trim(); if (t) out += t.split("\n").map((l) => "> " + l).join("\n") + "\n\n"; }
      else if (tag === "pre") { const t = (child.textContent || "").replace(/\s+$/, ""); if (t) out += "```\n" + t.replace(/```/g, "'''") + "\n```\n\n"; }
      else if (tag === "hr") out += "---\n\n";
      else if (tag === "table") out += table(child);
      else if (tag === "figure" || tag === "div" || tag === "section" || tag === "article" || tag === "main" || tag === "details" || tag === "li" || tag === "span" || tag === "header") {
        // A container with only inline content reads as one paragraph; otherwise its blocks are read in turn.
        const hasBlock = [...child.children].some((c) => /^(P|H[1-6]|UL|OL|BLOCKQUOTE|PRE|TABLE|DIV|SECTION|ARTICLE|FIGURE|HR)$/.test(c.tagName));
        if (hasBlock) out += blocks(child);
        else { const t = inline(child).trim(); if (t) out += t + "\n\n"; }
      } else { const t = inline({ childNodes: [child] }).trim(); if (t) out += t + "\n\n"; }
    }
    return out;
  }

  function meta(name) {
    const el = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]');
    return el ? (el.getAttribute("content") || "").trim() : "";
  }

  const main = findMain();
  let markdown = blocks(main).replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  let truncated = false;
  if (markdown.length > LIMIT) { markdown = markdown.slice(0, LIMIT); truncated = true; }
  const heading = main.querySelector("h1");
  return {
    title: (meta("og:title") || (heading && textOf(heading)) || document.title || "").slice(0, 300),
    url: location.href,
    site: meta("og:site_name"),
    byline: meta("author") || meta("article:author"),
    markdown,
    truncated,
  };
})();
