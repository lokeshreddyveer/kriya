//! Turns the HTML that apps put on the clipboard for formatted text into Markdown.
//!
//! It handles what ordinary copied text contains: headings, paragraphs, bold and italic (as tags or as inline
//! styles), links, lists, code, quotes, rules and images. Anything else keeps its text and loses its tag.

use regex::Regex;

#[derive(Debug, PartialEq)]
enum Token {
    Text(String),
    Open { name: String, attrs: String },
    Close(String),
}

fn tokenize(html: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut rest = html;
    while !rest.is_empty() {
        match rest.find('<') {
            None => {
                tokens.push(Token::Text(rest.to_string()));
                break;
            }
            Some(0) => {
                if let Some(stripped) = rest.strip_prefix("<!--") {
                    rest = stripped.find("-->").map_or("", |i| &stripped[i + 3..]);
                    continue;
                }
                let Some(end) = rest.find('>') else {
                    tokens.push(Token::Text(rest.to_string()));
                    break;
                };
                let inner = &rest[1..end];
                rest = &rest[end + 1..];
                if let Some(name) = inner.strip_prefix('/') {
                    tokens.push(Token::Close(name.trim().to_lowercase()));
                } else if inner.starts_with('!') || inner.starts_with('?') {
                    // A doctype or processing instruction: nothing to keep.
                } else {
                    let inner = inner.trim_end_matches('/').trim();
                    let (name, attrs) = match inner.find(char::is_whitespace) {
                        Some(i) => (&inner[..i], inner[i..].trim()),
                        None => (inner, ""),
                    };
                    tokens.push(Token::Open {
                        name: name.to_lowercase(),
                        attrs: attrs.to_string(),
                    });
                }
            }
            Some(i) => {
                tokens.push(Token::Text(rest[..i].to_string()));
                rest = &rest[i..];
            }
        }
    }
    tokens
}

fn attribute(attrs: &str, name: &str) -> Option<String> {
    let pattern = format!(r#"(?i)\b{name}\s*=\s*(?:"([^"]*)"|'([^']*)')"#);
    let re = Regex::new(&pattern).ok()?;
    let caps = re.captures(attrs)?;
    caps.get(1)
        .or_else(|| caps.get(2))
        .map(|m| decode_entities(m.as_str()))
}

fn decode_entities(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let Some(end) = rest.find(';').filter(|&e| e <= 10) else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let entity = &rest[1..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" | "#39" => Some('\''),
            "nbsp" => Some(' '),
            _ => entity
                .strip_prefix('#')
                .and_then(|n| {
                    n.strip_prefix(['x', 'X']).map_or_else(
                        || n.parse::<u32>().ok(),
                        |h| u32::from_str_radix(h, 16).ok(),
                    )
                })
                .and_then(char::from_u32),
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn ensure_blank_line(out: &mut String) {
    if out.is_empty() || out.ends_with("\n\n") {
        return;
    }
    if out.ends_with('\n') {
        out.push('\n');
    } else {
        out.push_str("\n\n");
    }
}

fn ensure_newline(out: &mut String) {
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
}

/// The Markdown for a piece of HTML.
pub fn html_to_markdown(html: &str) -> String {
    let mut out = String::new();
    // The closing marker each open inline tag owes.
    let mut stack: Vec<(String, String)> = Vec::new();
    let mut hrefs: Vec<String> = Vec::new();
    let mut lists: Vec<(bool, usize)> = Vec::new();
    let mut in_pre = false;
    let mut skipping: Option<String> = None;

    for token in tokenize(html) {
        if let Some(name) = &skipping {
            if matches!(&token, Token::Close(c) if c == name) {
                skipping = None;
            }
            continue;
        }
        match token {
            Token::Text(text) => {
                let text = decode_entities(&text);
                if in_pre {
                    out.push_str(&text);
                } else {
                    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
                    if collapsed.is_empty() {
                        if text.chars().any(char::is_whitespace)
                            && !out.is_empty()
                            && !out.ends_with(['\n', ' '])
                        {
                            out.push(' ');
                        }
                        continue;
                    }
                    let leading = text.starts_with(char::is_whitespace)
                        && !out.is_empty()
                        && !out.ends_with(['\n', ' ']);
                    if leading {
                        out.push(' ');
                    }
                    out.push_str(&collapsed);
                    if text.ends_with(char::is_whitespace) {
                        out.push(' ');
                    }
                }
            }
            Token::Open { name, attrs } => match name.as_str() {
                "script" | "style" | "head" | "title" => skipping = Some(name),
                "br" => out.push('\n'),
                "hr" => {
                    ensure_blank_line(&mut out);
                    out.push_str("---\n\n");
                }
                "p" | "div" | "section" | "article" | "table" | "tr" => ensure_blank_line(&mut out),
                "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                    ensure_blank_line(&mut out);
                    let level = name[1..].parse::<usize>().unwrap_or(1);
                    out.push_str(&"#".repeat(level));
                    out.push(' ');
                    stack.push((name, "\n\n".to_string()));
                }
                "strong" | "b" => {
                    out.push_str("**");
                    stack.push((name, "**".to_string()));
                }
                "em" | "i" => {
                    out.push('*');
                    stack.push((name, "*".to_string()));
                }
                "code" => {
                    if in_pre {
                        stack.push((name, String::new()));
                    } else {
                        out.push('`');
                        stack.push((name, "`".to_string()));
                    }
                }
                "pre" => {
                    ensure_blank_line(&mut out);
                    out.push_str("```\n");
                    in_pre = true;
                    stack.push((name, "\n```\n\n".to_string()));
                }
                "a" => {
                    let href = attribute(&attrs, "href").unwrap_or_default();
                    if href.is_empty() {
                        stack.push((name, String::new()));
                    } else {
                        out.push('[');
                        hrefs.push(href);
                        stack.push((name, "](\u{0}HREF)".to_string()));
                    }
                }
                "ul" | "ol" => {
                    if lists.is_empty() {
                        ensure_blank_line(&mut out);
                    } else {
                        ensure_newline(&mut out);
                    }
                    lists.push((name == "ol", 0));
                    stack.push((name, String::new()));
                }
                "li" => {
                    ensure_newline(&mut out);
                    let depth = lists.len().max(1);
                    out.push_str(&"  ".repeat(depth - 1));
                    match lists.last_mut() {
                        Some((true, n)) => {
                            *n += 1;
                            out.push_str(&format!("{n}. "));
                        }
                        _ => out.push_str("- "),
                    }
                    stack.push((name, String::new()));
                }
                "blockquote" => {
                    ensure_blank_line(&mut out);
                    out.push_str("> ");
                    stack.push((name, "\n\n".to_string()));
                }
                "img" => {
                    let alt = attribute(&attrs, "alt").unwrap_or_default();
                    if let Some(src) = attribute(&attrs, "src") {
                        out.push_str(&format!("![{alt}]({src})"));
                    }
                }
                "span" => {
                    let style = attribute(&attrs, "style")
                        .unwrap_or_default()
                        .to_lowercase()
                        .replace(' ', "");
                    let bold = style.contains("font-weight:bold")
                        || ["600", "700", "800", "900"]
                            .iter()
                            .any(|w| style.contains(&format!("font-weight:{w}")));
                    let italic = style.contains("font-style:italic");
                    let mut closing = String::new();
                    if bold {
                        out.push_str("**");
                        closing.insert_str(0, "**");
                    }
                    if italic {
                        out.push('*');
                        closing.insert(0, '*');
                    }
                    stack.push((name, closing));
                }
                _ => {}
            },
            Token::Close(name) => {
                match name.as_str() {
                    "p" | "div" | "section" | "article" | "table" | "tr" => {
                        ensure_blank_line(&mut out)
                    }
                    "ul" | "ol" => {
                        lists.pop();
                        if lists.is_empty() {
                            ensure_blank_line(&mut out);
                        }
                    }
                    "li" => ensure_newline(&mut out),
                    _ => {}
                }
                if let Some(pos) = stack.iter().rposition(|(n, _)| *n == name) {
                    let (_, closing) = stack.remove(pos);
                    if name == "pre" {
                        in_pre = false;
                    }
                    if closing.contains("\u{0}HREF") {
                        let href = hrefs.pop().unwrap_or_default();
                        out.push_str(&closing.replace("\u{0}HREF", &href));
                    } else {
                        out.push_str(&closing);
                    }
                }
            }
        }
    }
    clean(&out)
}

/// Trims the ends and never leaves more than one blank line in a row.
fn clean(text: &str) -> String {
    let mut lines: Vec<&str> = text.lines().map(str::trim_end).collect();
    let mut result = String::new();
    let mut blank = 0;
    lines.drain(..lines.iter().take_while(|l| l.is_empty()).count());
    for line in lines {
        if line.is_empty() {
            blank += 1;
            if blank > 1 {
                continue;
            }
        } else {
            blank = 0;
        }
        result.push_str(line);
        result.push('\n');
    }
    result.trim_end().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn headings_paragraphs_and_inline_formatting() {
        let html = "<h2>Title</h2><p>Some <b>bold</b> and <em>slanted</em> text.</p><p>Second.</p>";
        assert_eq!(
            html_to_markdown(html),
            "## Title\n\nSome **bold** and *slanted* text.\n\nSecond."
        );
    }

    #[test]
    fn links_images_and_code() {
        let html = r#"<p>See <a href="https://example.com/a?b=1&amp;c=2">the page</a> and <code>x = 1</code>.</p><img alt="logo" src="https://x/y.png">"#;
        assert_eq!(
            html_to_markdown(html),
            "See [the page](https://example.com/a?b=1&c=2) and `x = 1`.\n\n![logo](https://x/y.png)"
        );
        let pre = "<pre><code>line one\n  line two</code></pre>";
        assert_eq!(html_to_markdown(pre), "```\nline one\n  line two\n```");
    }

    #[test]
    fn lists_nest_and_numbered_lists_count() {
        let html =
            "<ul><li>one</li><li>two<ul><li>inner</li></ul></li></ul><ol><li>a</li><li>b</li></ol>";
        assert_eq!(
            html_to_markdown(html),
            "- one\n- two\n  - inner\n\n1. a\n2. b"
        );
    }

    #[test]
    fn inline_styles_from_mac_apps_become_bold_and_italic() {
        let html = r#"<span style="font-weight: bold">strong</span> <span style="font-style: italic">lean</span> <span style="font-weight: 700; font-style: italic">both</span>"#;
        assert_eq!(html_to_markdown(html), "**strong** *lean* ***both***");
    }

    #[test]
    fn scripts_styles_comments_and_entities() {
        let html = "<style>p { color: red }</style><!-- note --><p>Tom &amp; Jerry &lt;3 &#65;&nbsp;B</p><script>alert(1)</script>";
        assert_eq!(html_to_markdown(html), "Tom & Jerry <3 A B");
    }

    #[test]
    fn plain_text_quotes_and_rules_survive() {
        assert_eq!(html_to_markdown("just words"), "just words");
        assert_eq!(
            html_to_markdown("<blockquote>wise</blockquote><hr><p>after</p>"),
            "> wise\n\n---\n\nafter"
        );
        assert_eq!(html_to_markdown(""), "");
        assert_eq!(html_to_markdown("<p>broken <b>tag"), "broken **tag");
        assert_eq!(html_to_markdown("a &unknown; b & c"), "a &unknown; b & c");
    }
}
