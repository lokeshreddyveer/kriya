//! Text processing shared by the selection bar, text expansion and automation: case changes, cleaning up lines,
//! encoding, JSON, and link templates. Every function is pure: text in, text out, or a plain reason it cannot be done.

use serde::{Deserialize, Serialize};

pub const MAX_TEXT_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_OPS: usize = 20;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TextOp {
    Uppercase,
    Lowercase,
    TitleCase,
    SentenceCase,
    CamelCase,
    PascalCase,
    ConstantCase,
    SnakeCase,
    KebabCase,
    /// Removes spaces and blank lines at the start and end of the whole text.
    Trim,
    /// Removes spaces at the start and end of every line.
    TrimLines,
    /// Turns runs of spaces and tabs into one space.
    CollapseSpaces,
    RemoveBlankLines,
    RemoveDuplicateLines,
    SortLines {
        descending: bool,
        case_sensitive: bool,
        numeric: bool,
    },
    ReverseLines,
    PrefixLines {
        text: String,
    },
    SuffixLines {
        text: String,
    },
    UrlEncode,
    UrlDecode,
    HtmlEscape,
    HtmlUnescape,
    JsonFormat,
    JsonMinify,
    FindReplace {
        find: String,
        replace: String,
    },
    RegexReplace {
        pattern: String,
        replacement: String,
        case_insensitive: bool,
    },
    Wrap {
        before: String,
        after: String,
    },
    Base64Encode,
    Base64Decode,
    /// Escapes quotes, backslashes and line breaks so the text can sit inside a string in code.
    EscapeString,
    UnescapeString,
    /// `a, b, c` (or with semicolons) becomes one item per line.
    CommaToLines,
    /// One item per line becomes `a, b, c`.
    LinesToComma,
    ShuffleLines,
    /// Puts `1. `, `2. ` and so on in front of each line.
    NumberLines,
    /// `Hello, World!` becomes `hello-world`, for addresses and file names.
    Slugify,
    /// Takes the tracking parameters (`utm_source`, `fbclid` and the like) out of every web address in the text.
    StripUrlTracking,
    /// Keeps only the web addresses found in the text, one per line.
    ExtractUrls,
    /// Keeps only the email addresses found in the text, one per line.
    ExtractEmails,
    /// A number of seconds (or milliseconds) since 1970 becomes a date and time in UTC.
    UnixTimeToDate,
    /// A date and time in UTC (`2026-10-21 18:30:00`) becomes seconds since 1970.
    DateToUnixTime,
    /// Takes the line breaks out so the text reads as one line, with single spaces between what was on each line.
    JoinLines,
}

impl TextOp {
    pub fn title(&self) -> &'static str {
        match self {
            TextOp::Uppercase => "UPPERCASE",
            TextOp::Lowercase => "lowercase",
            TextOp::TitleCase => "Title Case",
            TextOp::SentenceCase => "Sentence case",
            TextOp::CamelCase => "camelCase",
            TextOp::PascalCase => "PascalCase",
            TextOp::ConstantCase => "CONSTANT_CASE",
            TextOp::SnakeCase => "snake_case",
            TextOp::KebabCase => "kebab-case",
            TextOp::Trim => "Trim whitespace",
            TextOp::TrimLines => "Trim each line",
            TextOp::CollapseSpaces => "Collapse spaces",
            TextOp::RemoveBlankLines => "Remove blank lines",
            TextOp::RemoveDuplicateLines => "Remove duplicate lines",
            TextOp::SortLines { .. } => "Sort lines",
            TextOp::ReverseLines => "Reverse lines",
            TextOp::PrefixLines { .. } => "Add text before each line",
            TextOp::SuffixLines { .. } => "Add text after each line",
            TextOp::UrlEncode => "URL encode",
            TextOp::UrlDecode => "URL decode",
            TextOp::HtmlEscape => "HTML escape",
            TextOp::HtmlUnescape => "HTML unescape",
            TextOp::JsonFormat => "Format JSON",
            TextOp::JsonMinify => "Minify JSON",
            TextOp::FindReplace { .. } => "Find and replace",
            TextOp::RegexReplace { .. } => "Regex replace",
            TextOp::Wrap { .. } => "Wrap with text",
            TextOp::Base64Encode => "Base64 encode",
            TextOp::Base64Decode => "Base64 decode",
            TextOp::EscapeString => "Escape for a string",
            TextOp::UnescapeString => "Unescape a string",
            TextOp::CommaToLines => "Comma list to lines",
            TextOp::LinesToComma => "Lines to comma list",
            TextOp::ShuffleLines => "Shuffle lines",
            TextOp::NumberLines => "Number the lines",
            TextOp::Slugify => "Make a slug",
            TextOp::StripUrlTracking => "Clean tracking from links",
            TextOp::ExtractUrls => "Keep only the links",
            TextOp::ExtractEmails => "Keep only the email addresses",
            TextOp::UnixTimeToDate => "Unix time to date",
            TextOp::DateToUnixTime => "Date to Unix time",
            TextOp::JoinLines => "Remove line breaks",
        }
    }
}

/// The text as HTML: blank lines separate paragraphs, a single line break becomes `<br>`, and everything is escaped.
pub fn text_to_html(text: &str) -> String {
    let normalized = text.replace("\r\n", "\n");
    normalized
        .trim()
        .split("\n\n")
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| format!("<p>{}</p>", html_escape(p).replace('\n', "<br>\n")))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Every line joined into one, with single spaces where the breaks were.
fn join_lines(text: &str) -> String {
    text.split(['\n', '\r'])
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Runs one step. The error is a plain sentence for the person.
pub fn apply(op: &TextOp, text: &str) -> Result<String, String> {
    if text.len() > MAX_TEXT_BYTES {
        return Err("the text is too long".into());
    }
    Ok(match op {
        TextOp::Uppercase => text.to_uppercase(),
        TextOp::Lowercase => text.to_lowercase(),
        TextOp::TitleCase => title_case(text),
        TextOp::SentenceCase => sentence_case(text),
        TextOp::CamelCase => join_words(text, WordStyle::Camel),
        TextOp::PascalCase => join_words(text, WordStyle::Pascal),
        TextOp::ConstantCase => join_words(text, WordStyle::Constant),
        TextOp::SnakeCase => join_words(text, WordStyle::Snake),
        TextOp::KebabCase => join_words(text, WordStyle::Kebab),
        TextOp::Trim => text.trim().to_string(),
        TextOp::TrimLines => map_lines(text, |l| l.trim().to_string()),
        TextOp::CollapseSpaces => collapse_spaces(text),
        TextOp::RemoveBlankLines => lines(text)
            .into_iter()
            .filter(|l| !l.trim().is_empty())
            .collect::<Vec<_>>()
            .join(newline(text)),
        TextOp::RemoveDuplicateLines => remove_duplicate_lines(text),
        TextOp::SortLines {
            descending,
            case_sensitive,
            numeric,
        } => sort_lines(text, *descending, *case_sensitive, *numeric),
        TextOp::ReverseLines => {
            let mut l = lines(text);
            l.reverse();
            l.join(newline(text))
        }
        TextOp::PrefixLines { text: prefix } => map_lines(text, |l| format!("{prefix}{l}")),
        TextOp::SuffixLines { text: suffix } => map_lines(text, |l| format!("{l}{suffix}")),
        TextOp::UrlEncode => url_encode(text),
        TextOp::UrlDecode => url_decode(text)?,
        TextOp::HtmlEscape => html_escape(text),
        TextOp::HtmlUnescape => html_unescape(text),
        TextOp::JsonFormat => json_format(text)?,
        TextOp::JsonMinify => json_minify(text)?,
        TextOp::FindReplace { find, replace } => {
            if find.is_empty() {
                return Err("there is nothing to find".into());
            }
            text.replace(find.as_str(), replace)
        }
        TextOp::RegexReplace {
            pattern,
            replacement,
            case_insensitive,
        } => {
            let re = regex::RegexBuilder::new(pattern)
                .case_insensitive(*case_insensitive)
                .size_limit(1 << 20)
                .build()
                .map_err(|_| "the pattern is not a valid regular expression".to_string())?;
            re.replace_all(text, replacement.as_str()).into_owned()
        }
        TextOp::Wrap { before, after } => format!("{before}{text}{after}"),
        TextOp::Base64Encode => base64_encode(text),
        TextOp::Base64Decode => base64_decode(text)?,
        TextOp::EscapeString => escape_string(text),
        TextOp::UnescapeString => unescape_string(text)?,
        TextOp::CommaToLines => text
            .split([',', ';', '\n'])
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .collect::<Vec<_>>()
            .join(newline(text)),
        TextOp::LinesToComma => lines(text)
            .into_iter()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .collect::<Vec<_>>()
            .join(", "),
        TextOp::ShuffleLines => shuffle_lines(text),
        TextOp::NumberLines => lines(text)
            .into_iter()
            .enumerate()
            .map(|(i, l)| format!("{}. {l}", i + 1))
            .collect::<Vec<_>>()
            .join(newline(text)),
        TextOp::Slugify => slugify(text),
        TextOp::StripUrlTracking => strip_url_tracking(text),
        TextOp::ExtractUrls => extract_matches(text, URL_PATTERN)?,
        TextOp::ExtractEmails => extract_matches(text, EMAIL_PATTERN)?,
        TextOp::UnixTimeToDate => unix_to_date(text)?,
        TextOp::DateToUnixTime => date_to_unix(text)?,
        TextOp::JoinLines => join_lines(text),
    })
}

const URL_PATTERN: &str = r#"https?://[^\s<>"')\]]+"#;
const EMAIL_PATTERN: &str = r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}";

/// The lines in a random order. The order comes from the system's own randomness, so no two shuffles agree.
fn shuffle_lines(text: &str) -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    let mut l: Vec<&str> = lines(text);
    let state = RandomState::new();
    // Fisher-Yates, with a fresh hash for each step.
    for i in (1..l.len()).rev() {
        let mut hasher = state.build_hasher();
        hasher.write_usize(i);
        let j = (hasher.finish() % (i as u64 + 1)) as usize;
        l.swap(i, j);
    }
    l.join(newline(text))
}

fn slugify(text: &str) -> String {
    let mut out = String::new();
    let mut pending_dash = false;
    for c in text.chars() {
        if c.is_alphanumeric() {
            if pending_dash && !out.is_empty() {
                out.push('-');
            }
            pending_dash = false;
            out.extend(c.to_lowercase());
        } else {
            pending_dash = true;
        }
    }
    out
}

fn strip_url_tracking(text: &str) -> String {
    match regex::Regex::new(URL_PATTERN) {
        Ok(re) => re
            .replace_all(text, |caps: &regex::Captures| {
                let whole = &caps[0];
                // Punctuation that ends a sentence is not part of the address.
                let trimmed = whole.trim_end_matches(['.', ',', ';', ':', '!', '?']);
                let tail = &whole[trimmed.len()..];
                format!(
                    "{}{}",
                    crate::link_routing::strip_tracking(trimmed, &[]).0,
                    tail
                )
            })
            .into_owned(),
        Err(_) => text.to_string(),
    }
}

fn extract_matches(text: &str, pattern: &str) -> Result<String, String> {
    let re = regex::Regex::new(pattern).map_err(|_| "the pattern is not valid".to_string())?;
    let found: Vec<&str> = re
        .find_iter(text)
        .map(|m| m.as_str().trim_end_matches(['.', ',', ';', ':', '!', '?']))
        .collect();
    if found.is_empty() {
        return Err("nothing was found".into());
    }
    Ok(found.join(newline(text)))
}

/// Days since 1970-01-01 to a calendar date (proleptic Gregorian, UTC).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = if m > 2 { m - 3 } else { m + 9 } as i64;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn unix_to_date(text: &str) -> Result<String, String> {
    map_lines_result(text, |line| {
        let n: i64 = line
            .trim()
            .parse()
            .map_err(|_| "that is not a number".to_string())?;
        // More than 11 digits is milliseconds, not seconds.
        let seconds = if n.abs() >= 100_000_000_000 {
            n / 1000
        } else {
            n
        };
        if seconds.abs() > 253_402_300_799 {
            return Err("that is outside the years 0 to 9999".to_string());
        }
        let (y, m, d) = civil_from_days(seconds.div_euclid(86_400));
        let rest = seconds.rem_euclid(86_400);
        Ok(format!(
            "{y:04}-{m:02}-{d:02} {:02}:{:02}:{:02} UTC",
            rest / 3600,
            rest % 3600 / 60,
            rest % 60
        ))
    })
}

fn date_to_unix(text: &str) -> Result<String, String> {
    map_lines_result(text, |line| {
        let cleaned = line
            .trim()
            .trim_end_matches("UTC")
            .trim_end_matches('Z')
            .trim()
            .replace('T', " ");
        let mut parts = cleaned.split_whitespace();
        let date = parts.next().ok_or_else(|| "there is no date".to_string())?;
        let time = parts.next().unwrap_or("00:00:00");
        let d: Vec<u32> = date.split('-').filter_map(|p| p.parse().ok()).collect();
        let t: Vec<u32> = time.split(':').filter_map(|p| p.parse().ok()).collect();
        if d.len() != 3
            || t.len() < 2
            || !(1..=12).contains(&d[1])
            || !(1..=31).contains(&d[2])
            || t[0] > 23
            || t[1] > 59
            || t.get(2).is_some_and(|s| *s > 59)
        {
            return Err("use a date like 2026-10-21 18:30:00".to_string());
        }
        let days = days_from_civil(d[0] as i64, d[1], d[2]);
        Ok(
            (days * 86_400
                + t[0] as i64 * 3600
                + t[1] as i64 * 60
                + *t.get(2).unwrap_or(&0) as i64)
                .to_string(),
        )
    })
}

/// Runs a step on every line and stops at the first line that cannot be done.
fn map_lines_result(
    text: &str,
    mut f: impl FnMut(&str) -> Result<String, String>,
) -> Result<String, String> {
    let mut out = Vec::new();
    for line in lines(text) {
        out.push(f(line)?);
    }
    Ok(out.join(newline(text)))
}

/// Runs the steps in order. Stops at the first one that cannot be done and says which.
pub fn apply_all(ops: &[TextOp], text: &str) -> Result<String, String> {
    if ops.len() > MAX_OPS {
        return Err("there are too many steps".into());
    }
    let mut current = text.to_string();
    for (i, op) in ops.iter().enumerate() {
        current =
            apply(op, &current).map_err(|e| format!("step {} ({}): {e}", i + 1, op.title()))?;
    }
    Ok(current)
}

/// Checks that a pipeline is usable (the patterns compile) without needing any text.
pub fn check_ops(ops: &[TextOp]) -> Result<(), String> {
    if ops.is_empty() {
        return Err("add at least one step".into());
    }
    if ops.len() > MAX_OPS {
        return Err("there are too many steps".into());
    }
    for op in ops {
        match op {
            TextOp::RegexReplace { pattern, .. } if pattern.is_empty() || pattern.len() > 500 => {
                return Err("the pattern is empty or too long".into());
            }
            TextOp::RegexReplace {
                pattern,
                case_insensitive,
                ..
            } => {
                regex::RegexBuilder::new(pattern)
                    .case_insensitive(*case_insensitive)
                    .size_limit(1 << 20)
                    .build()
                    .map_err(|_| "the pattern is not a valid regular expression".to_string())?;
            }
            TextOp::FindReplace { find, .. } if find.is_empty() => {
                return Err("there is nothing to find".into())
            }
            _ => {}
        }
    }
    Ok(())
}

// ---- lines -----------------------------------------------------------------------------------------------------------

fn newline(text: &str) -> &'static str {
    if text.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    }
}

fn lines(text: &str) -> Vec<&str> {
    text.split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .collect()
}

fn map_lines(text: &str, f: impl Fn(&str) -> String) -> String {
    lines(text)
        .into_iter()
        .map(f)
        .collect::<Vec<_>>()
        .join(newline(text))
}

fn remove_duplicate_lines(text: &str) -> String {
    let mut seen = std::collections::HashSet::new();
    let kept: Vec<&str> = lines(text)
        .into_iter()
        .filter(|l| seen.insert(*l))
        .collect();
    kept.join(newline(text))
}

fn sort_lines(text: &str, descending: bool, case_sensitive: bool, numeric: bool) -> String {
    let trailing = text.ends_with('\n');
    let mut l: Vec<&str> = lines(text.strip_suffix('\n').unwrap_or(text));
    l.sort_by(|a, b| {
        let ord = if numeric {
            match (leading_number(a), leading_number(b)) {
                (Some(x), Some(y)) => x.partial_cmp(&y).unwrap_or(std::cmp::Ordering::Equal),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => compare_text(a, b, case_sensitive),
            }
        } else {
            compare_text(a, b, case_sensitive)
        };
        if descending {
            ord.reverse()
        } else {
            ord
        }
    });
    let mut out = l.join(newline(text));
    if trailing {
        out.push('\n');
    }
    out
}

fn compare_text(a: &str, b: &str, case_sensitive: bool) -> std::cmp::Ordering {
    if case_sensitive {
        a.cmp(b)
    } else {
        a.to_lowercase()
            .cmp(&b.to_lowercase())
            .then_with(|| a.cmp(b))
    }
}

fn leading_number(s: &str) -> Option<f64> {
    let t = s.trim_start();
    let end = t
        .char_indices()
        .take_while(|(i, c)| {
            c.is_ascii_digit() || *c == '.' || (*i == 0 && (*c == '-' || *c == '+'))
        })
        .last()
        .map(|(i, c)| i + c.len_utf8())?;
    t[..end].parse().ok()
}

fn collapse_spaces(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    for c in text.chars() {
        if c == ' ' || c == '\t' {
            if !space {
                out.push(' ');
            }
            space = true;
        } else {
            space = false;
            out.push(c);
        }
    }
    out
}

// ---- case ------------------------------------------------------------------------------------------------------------

fn title_case(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut start = true;
    for c in text.chars() {
        if c.is_alphanumeric() {
            if start {
                out.extend(c.to_uppercase());
            } else {
                out.extend(c.to_lowercase());
            }
            start = false;
        } else {
            out.push(c);
            // An apostrophe inside a word ("don't") does not start a new word.
            if c != '\'' && c != '’' {
                start = true;
            }
        }
    }
    out
}

fn sentence_case(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut capitalize = true;
    for c in text.chars() {
        if c.is_alphabetic() {
            if capitalize {
                out.extend(c.to_uppercase());
                capitalize = false;
            } else {
                out.extend(c.to_lowercase());
            }
        } else {
            out.push(c);
            if matches!(c, '.' | '!' | '?' | '\n') {
                capitalize = true;
            }
        }
    }
    out
}

enum WordStyle {
    Camel,
    Pascal,
    Constant,
    Snake,
    Kebab,
}

/// Splits on anything that is not a letter or digit and on lower-to-upper changes, then joins in the chosen style.
fn join_words(text: &str, style: WordStyle) -> String {
    map_lines(text, |line| {
        let mut words: Vec<String> = Vec::new();
        let mut current = String::new();
        let mut previous_lower = false;
        for c in line.chars() {
            if c.is_alphanumeric() {
                if c.is_uppercase() && previous_lower && !current.is_empty() {
                    words.push(std::mem::take(&mut current));
                }
                current.push(c);
                previous_lower = c.is_lowercase() || c.is_ascii_digit();
            } else {
                if !current.is_empty() {
                    words.push(std::mem::take(&mut current));
                }
                previous_lower = false;
            }
        }
        if !current.is_empty() {
            words.push(current);
        }
        match style {
            WordStyle::Snake => words
                .iter()
                .map(|w| w.to_lowercase())
                .collect::<Vec<_>>()
                .join("_"),
            WordStyle::Kebab => words
                .iter()
                .map(|w| w.to_lowercase())
                .collect::<Vec<_>>()
                .join("-"),
            WordStyle::Camel => words
                .iter()
                .enumerate()
                .map(|(i, w)| {
                    let lower = w.to_lowercase();
                    if i == 0 {
                        lower
                    } else {
                        let mut chars = lower.chars();
                        chars.next().map_or_else(String::new, |f| {
                            f.to_uppercase().collect::<String>() + chars.as_str()
                        })
                    }
                })
                .collect(),
            WordStyle::Pascal => words
                .iter()
                .map(|w| capitalized(&w.to_lowercase()))
                .collect(),
            WordStyle::Constant => words
                .iter()
                .map(|w| w.to_uppercase())
                .collect::<Vec<_>>()
                .join("_"),
        }
    })
}

/// The word with its first letter in upper case.
fn capitalized(word: &str) -> String {
    let mut chars = word.chars();
    chars.next().map_or_else(String::new, |f| {
        f.to_uppercase().collect::<String>() + chars.as_str()
    })
}

// ---- encodings -------------------------------------------------------------------------------------------------------

const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64_encode(text: &str) -> String {
    let mut out = String::new();
    for chunk in text.as_bytes().chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(BASE64[(n >> 18) as usize & 63] as char);
        out.push(BASE64[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            BASE64[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            BASE64[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// Accepts the standard and the URL-safe alphabets, with or without padding and line breaks.
pub fn base64_decode(text: &str) -> Result<String, String> {
    let mut values: Vec<u32> = Vec::new();
    for c in text.chars().filter(|c| !c.is_whitespace() && *c != '=') {
        let value = match c {
            'A'..='Z' => c as u32 - 'A' as u32,
            'a'..='z' => c as u32 - 'a' as u32 + 26,
            '0'..='9' => c as u32 - '0' as u32 + 52,
            '+' | '-' => 62,
            '/' | '_' => 63,
            _ => return Err("that is not valid Base64".into()),
        };
        values.push(value);
    }
    if values.len() % 4 == 1 {
        return Err("that is not valid Base64".into());
    }
    let mut bytes: Vec<u8> = Vec::new();
    for group in values.chunks(4) {
        let mut n = 0u32;
        for (i, v) in group.iter().enumerate() {
            n |= v << (18 - 6 * i);
        }
        let produced = group.len() - 1;
        for i in 0..produced {
            bytes.push((n >> (16 - 8 * i)) as u8);
        }
    }
    String::from_utf8(bytes).map_err(|_| "the result is not text".to_string())
}

pub fn escape_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// The reverse of `escape_string`. A backslash before anything it does not know is kept as it is.
pub fn unescape_string(text: &str) -> Result<String, String> {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some('"') => out.push('"'),
            Some('\'') => out.push('\''),
            Some('/') => out.push('/'),
            Some('\\') => out.push('\\'),
            Some('u') => {
                let hex: String = chars.by_ref().take(4).collect();
                if hex.chars().count() != 4 {
                    return Err("a \\u escape needs four hex digits".to_string());
                }
                let code = u32::from_str_radix(&hex, 16)
                    .map_err(|_| "a \\u escape needs four hex digits".to_string())?;
                out.push(
                    char::from_u32(code)
                        .ok_or_else(|| "that is not a valid character".to_string())?,
                );
            }
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    Ok(out)
}

pub fn url_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len() * 3);
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

pub fn url_decode(text: &str) -> Result<String, String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text
                .get(i + 1..i + 3)
                .ok_or_else(|| "the text has an incomplete %-code".to_string())?;
            out.push(
                u8::from_str_radix(hex, 16)
                    .map_err(|_| "the text has an invalid %-code".to_string())?,
            );
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(|_| "the decoded text is not valid UTF-8".to_string())
}

pub fn html_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

pub fn html_unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find('&') {
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        match tail.find(';').filter(|end| *end <= 10) {
            Some(end) => {
                let entity = &tail[1..end];
                let decoded = match entity {
                    "amp" => Some('&'),
                    "lt" => Some('<'),
                    "gt" => Some('>'),
                    "quot" => Some('"'),
                    "apos" => Some('\''),
                    "nbsp" => Some('\u{a0}'),
                    e if e.starts_with("#x") || e.starts_with("#X") => {
                        u32::from_str_radix(&e[2..], 16)
                            .ok()
                            .and_then(char::from_u32)
                    }
                    e if e.starts_with('#') => e[1..].parse::<u32>().ok().and_then(char::from_u32),
                    _ => None,
                };
                match decoded {
                    Some(c) => {
                        out.push(c);
                        rest = &tail[end + 1..];
                    }
                    None => {
                        out.push('&');
                        rest = &tail[1..];
                    }
                }
            }
            None => {
                out.push('&');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

// ---- JSON ------------------------------------------------------------------------------------------------------------

fn parse_json(text: &str) -> Result<serde_json::Value, String> {
    serde_json::from_str(text).map_err(|e| {
        format!(
            "not valid JSON: {} (line {}, column {})",
            short(&e.to_string()),
            e.line(),
            e.column()
        )
    })
}

fn short(message: &str) -> String {
    // serde_json appends " at line X column Y"; the position is given separately.
    message
        .split(" at line ")
        .next()
        .unwrap_or(message)
        .to_string()
}

pub fn json_format(text: &str) -> Result<String, String> {
    serde_json::to_string_pretty(&parse_json(text)?).map_err(|e| e.to_string())
}

pub fn json_minify(text: &str) -> Result<String, String> {
    serde_json::to_string(&parse_json(text)?).map_err(|e| e.to_string())
}

/// `Ok` when the text is valid JSON, otherwise what is wrong and where.
pub fn json_validate(text: &str) -> Result<(), String> {
    parse_json(text).map(|_| ())
}

// ---- links -----------------------------------------------------------------------------------------------------------

const BLOCKED_SCHEMES: [&str; 4] = ["javascript", "data", "vbscript", "file"];

/// Fills a link template: `{text}` becomes the selection encoded for a link, `{raw}` leaves it as it is and `{plus}`
/// encodes spaces as +. The result must be a real link that is not a script.
pub fn expand_url_template(template: &str, text: &str) -> Result<String, String> {
    if !template.contains("{text}") && !template.contains("{raw}") && !template.contains("{plus}") {
        return Err("the address needs {text} where the selection goes".into());
    }
    let trimmed = text.trim();
    let url = template
        .replace("{text}", &url_encode(trimmed))
        .replace("{plus}", &url_encode(trimmed).replace("%20", "+"))
        .replace("{raw}", trimmed);
    let parsed =
        url::Url::parse(&url).map_err(|_| "that does not make a valid address".to_string())?;
    if BLOCKED_SCHEMES.contains(&parsed.scheme()) {
        return Err(format!("{} addresses are not allowed", parsed.scheme()));
    }
    Ok(url)
}

/// Checks a template without any text.
pub fn check_url_template(template: &str) -> Result<(), String> {
    expand_url_template(template, "example").map(|_| ())
}

/// The web addresses in some text. A bare domain such as `example.com` counts and gets `https://`.
pub fn find_urls(text: &str) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    for word in text.split(|c: char| {
        c.is_whitespace() || matches!(c, '<' | '>' | '"' | '\'' | '(' | ')' | '[' | ']')
    }) {
        let w = word.trim_end_matches(['.', ',', ';', ':', '!', '?']);
        if let Some(url) = normalize_url(w) {
            if !found.contains(&url) {
                found.push(url);
            }
        }
    }
    found
}

pub fn normalize_url(text: &str) -> Option<String> {
    let t = text.trim();
    if t.is_empty() || t.len() > 2048 {
        return None;
    }
    if let Ok(u) = url::Url::parse(t) {
        return (matches!(u.scheme(), "http" | "https" | "ftp" | "mailto")
            && (u.has_host() || u.scheme() == "mailto"))
            .then(|| t.to_string());
    }
    let host = t.split(['/', '?', '#']).next()?;
    let labels: Vec<&str> = host.split('.').collect();
    let looks_like_domain = labels.len() >= 2
        && labels.iter().all(|l| {
            !l.is_empty()
                && l.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
                && !l.starts_with('-')
                && !l.ends_with('-')
        })
        && labels
            .last()
            .is_some_and(|tld| tld.len() >= 2 && tld.chars().all(|c| c.is_ascii_alphabetic()));
    looks_like_domain.then(|| format!("https://{t}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(op: TextOp, text: &str) -> String {
        apply(&op, text).unwrap()
    }

    #[test]
    fn case_changes() {
        assert_eq!(run(TextOp::Uppercase, "straße café"), "STRASSE CAFÉ");
        assert_eq!(run(TextOp::Lowercase, "Hello WORLD"), "hello world");
        assert_eq!(
            run(TextOp::TitleCase, "the quick brown fox's den-of-thieves"),
            "The Quick Brown Fox's Den-Of-Thieves"
        );
        assert_eq!(
            run(
                TextOp::SentenceCase,
                "hELLO there. how ARE you? fine!\nnew line"
            ),
            "Hello there. How are you? Fine!\nNew line"
        );
        assert_eq!(
            run(TextOp::CamelCase, "hello big_world-again"),
            "helloBigWorldAgain"
        );
        assert_eq!(run(TextOp::SnakeCase, "HelloBigWorld"), "hello_big_world");
        assert_eq!(run(TextOp::KebabCase, "Hello big World"), "hello-big-world");
    }

    #[test]
    fn line_breaks_come_out_and_html_is_escaped_into_paragraphs() {
        assert_eq!(
            run(TextOp::JoinLines, "one\n  two \r\n\n three"),
            "one two three"
        );
        assert_eq!(run(TextOp::JoinLines, "single"), "single");
        assert_eq!(
            text_to_html("Tom & <Jerry>\nsecond line\n\nNext paragraph"),
            "<p>Tom &amp; &lt;Jerry&gt;<br>\nsecond line</p>\n<p>Next paragraph</p>"
        );
        assert_eq!(text_to_html("  \n "), "");
    }

    #[test]
    fn whitespace_and_blank_lines() {
        assert_eq!(run(TextOp::Trim, "\n  hi there \n\n"), "hi there");
        assert_eq!(run(TextOp::TrimLines, "  a  \n\tb\t"), "a\nb");
        assert_eq!(run(TextOp::CollapseSpaces, "a   b\t\tc"), "a b c");
        assert_eq!(run(TextOp::RemoveBlankLines, "a\n\n  \nb"), "a\nb");
    }

    #[test]
    fn duplicates_sorting_and_reversing_keep_the_line_endings() {
        assert_eq!(
            run(TextOp::RemoveDuplicateLines, "a\nb\na\nc\nb"),
            "a\nb\nc"
        );
        assert_eq!(run(TextOp::RemoveDuplicateLines, "a\r\nb\r\na"), "a\r\nb");
        let sort = |d, c, n| TextOp::SortLines {
            descending: d,
            case_sensitive: c,
            numeric: n,
        };
        assert_eq!(
            run(sort(false, false, false), "banana\nApple\ncherry\n"),
            "Apple\nbanana\ncherry\n"
        );
        assert_eq!(run(sort(true, false, false), "a\nc\nb"), "c\nb\na");
        assert_eq!(run(sort(false, true, false), "b\nB\na"), "B\na\nb");
        assert_eq!(
            run(
                sort(false, false, true),
                "10 apples\n9 pears\n100 plums\nzebra\n-5 cold"
            ),
            "-5 cold\n9 pears\n10 apples\n100 plums\nzebra"
        );
        assert_eq!(run(TextOp::ReverseLines, "1\n2\n3"), "3\n2\n1");
    }

    #[test]
    fn lines_get_text_added() {
        assert_eq!(
            run(TextOp::PrefixLines { text: "- ".into() }, "a\nb"),
            "- a\n- b"
        );
        assert_eq!(
            run(TextOp::SuffixLines { text: ";".into() }, "a\nb"),
            "a;\nb;"
        );
        assert_eq!(
            run(
                TextOp::Wrap {
                    before: "(".into(),
                    after: ")".into()
                },
                "x"
            ),
            "(x)"
        );
    }

    #[test]
    fn url_encoding_round_trips_including_unicode() {
        let text = "a b&c=d/é?";
        let encoded = run(TextOp::UrlEncode, text);
        assert_eq!(encoded, "a%20b%26c%3Dd%2F%C3%A9%3F");
        assert_eq!(run(TextOp::UrlDecode, &encoded), text);
        assert!(apply(&TextOp::UrlDecode, "100%").is_err());
        assert!(apply(&TextOp::UrlDecode, "%zz").is_err());
        assert!(apply(&TextOp::UrlDecode, "%FF").is_err(), "not valid UTF-8");
    }

    #[test]
    fn html_escaping_round_trips() {
        let text = "<a href=\"x\">Tom & Jerry's</a>";
        let escaped = run(TextOp::HtmlEscape, text);
        assert_eq!(
            escaped,
            "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;"
        );
        assert_eq!(run(TextOp::HtmlUnescape, &escaped), text);
        assert_eq!(
            run(TextOp::HtmlUnescape, "&#65;&#x42;&nbsp;&unknown; & done"),
            "AB\u{a0}&unknown; & done"
        );
    }

    #[test]
    fn json_is_formatted_minified_and_validated_with_a_position() {
        let formatted = run(TextOp::JsonFormat, "{\"b\":1,\"a\":[1,2]}");
        assert_eq!(
            formatted, "{\n  \"b\": 1,\n  \"a\": [\n    1,\n    2\n  ]\n}",
            "key order is kept"
        );
        assert_eq!(run(TextOp::JsonMinify, &formatted), "{\"b\":1,\"a\":[1,2]}");
        assert!(json_validate("{\"a\": 1}").is_ok());
        let err = json_validate("{\n  \"a\": 1,\n}").unwrap_err();
        assert!(
            err.contains("not valid JSON") && err.contains("line 3"),
            "{err}"
        );
        assert!(apply(&TextOp::JsonFormat, "nope").is_err());
    }

    #[test]
    fn find_replace_and_regex() {
        assert_eq!(
            run(
                TextOp::FindReplace {
                    find: "cat".into(),
                    replace: "dog".into()
                },
                "cat catalog"
            ),
            "dog dogalog"
        );
        assert!(apply(
            &TextOp::FindReplace {
                find: String::new(),
                replace: "x".into()
            },
            "a"
        )
        .is_err());
        let re = |p: &str, r: &str, ci| TextOp::RegexReplace {
            pattern: p.into(),
            replacement: r.into(),
            case_insensitive: ci,
        };
        assert_eq!(
            run(re(r"(\d+)-(\d+)", "$2-$1", false), "10-20 and 3-4"),
            "20-10 and 4-3"
        );
        assert_eq!(run(re("hello", "bye", true), "HeLLo"), "bye");
        assert!(apply(&re("(unclosed", "", false), "x").is_err());
    }

    #[test]
    fn pipelines_run_in_order_and_name_the_failing_step() {
        let ops = vec![
            TextOp::Trim,
            TextOp::Lowercase,
            TextOp::RemoveDuplicateLines,
            TextOp::SortLines {
                descending: false,
                case_sensitive: false,
                numeric: false,
            },
        ];
        assert_eq!(apply_all(&ops, "  B\na\nb\nA\n").unwrap(), "a\nb");
        let bad = vec![TextOp::Trim, TextOp::JsonFormat];
        assert!(apply_all(&bad, "not json")
            .unwrap_err()
            .starts_with("step 2 (Format JSON)"));
        assert!(apply_all(&vec![TextOp::Trim; 30], "x").is_err());
        assert!(apply(&TextOp::Trim, &"x".repeat(MAX_TEXT_BYTES + 1)).is_err());
    }

    #[test]
    fn pipelines_are_checked_without_text() {
        assert!(check_ops(&[]).is_err());
        assert!(check_ops(&[TextOp::Uppercase]).is_ok());
        assert!(check_ops(&[TextOp::RegexReplace {
            pattern: "(".into(),
            replacement: String::new(),
            case_insensitive: false
        }])
        .is_err());
        assert!(check_ops(&[TextOp::FindReplace {
            find: String::new(),
            replace: String::new()
        }])
        .is_err());
    }

    #[test]
    fn link_templates_encode_the_selection_and_refuse_scripts() {
        assert_eq!(
            expand_url_template("https://www.google.com/search?q={text}", "rust & go").unwrap(),
            "https://www.google.com/search?q=rust%20%26%20go"
        );
        assert_eq!(
            expand_url_template("https://duckduckgo.com/?q={plus}", "a b").unwrap(),
            "https://duckduckgo.com/?q=a+b"
        );
        assert_eq!(
            expand_url_template("https://example.com/{raw}", "a/b").unwrap(),
            "https://example.com/a/b"
        );
        assert!(
            expand_url_template("https://example.com/", "x").is_err(),
            "no placeholder"
        );
        assert!(expand_url_template("javascript:alert({text})", "x").is_err());
        assert!(expand_url_template("not a link {text}", "x").is_err());
        assert!(check_url_template("https://x.test/?q={text}").is_ok());
    }

    #[test]
    fn urls_are_found_in_text() {
        assert_eq!(
            find_urls("see https://example.com/a?b=1, and example.org."),
            vec![
                "https://example.com/a?b=1".to_string(),
                "https://example.org".to_string()
            ]
        );
        assert!(find_urls("no links here, just words.").is_empty());
        assert!(
            find_urls("version 1.2.3 released").is_empty(),
            "numbers with dots are not domains"
        );
        assert_eq!(
            normalize_url("www.example.com/path"),
            Some("https://www.example.com/path".into())
        );
        assert_eq!(normalize_url("javascript:alert(1)"), None);
        assert_eq!(
            normalize_url("a.b"),
            None,
            "a one-letter ending is not a domain"
        );
    }

    #[test]
    fn base64_round_trips_and_accepts_the_common_variants() {
        assert_eq!(base64_encode(""), "");
        assert_eq!(base64_encode("f"), "Zg==");
        assert_eq!(base64_encode("fo"), "Zm8=");
        assert_eq!(base64_encode("foo"), "Zm9v");
        for text in ["", "a", "ab", "abc", "Hello, wörld ✓", "line\nbreak"] {
            assert_eq!(base64_decode(&base64_encode(text)).unwrap(), text);
        }
        assert_eq!(
            base64_decode("Zm9v\nYmFy").unwrap(),
            "foobar",
            "line breaks are ignored"
        );
        assert_eq!(base64_decode("Zm8").unwrap(), "fo", "padding is optional");
        assert!(base64_decode("not base64!").is_err());
        assert!(
            base64_decode("A").is_err(),
            "one stray character cannot be decoded"
        );
        assert!(
            base64_decode("/w==").is_err(),
            "bytes that are not text are refused"
        );
    }

    #[test]
    fn strings_escape_and_unescape() {
        let original = "say \"hi\"\\\n\ttab";
        let escaped = escape_string(original);
        assert_eq!(escaped, "say \\\"hi\\\"\\\\\\n\\ttab");
        assert_eq!(unescape_string(&escaped).unwrap(), original);
        assert_eq!(unescape_string("caf\\u00e9").unwrap(), "café");
        assert_eq!(unescape_string("keep \\q this").unwrap(), "keep \\q this");
        assert!(unescape_string("bad \\u12").is_err());
        assert_eq!(escape_string("\u{1}"), "\\u0001");
    }

    #[test]
    fn pascal_and_constant_case_join_words() {
        assert_eq!(run(TextOp::PascalCase, "hello big world"), "HelloBigWorld");
        assert_eq!(
            run(TextOp::PascalCase, "get_http response"),
            "GetHttpResponse"
        );
        assert_eq!(
            run(TextOp::ConstantCase, "hello big world"),
            "HELLO_BIG_WORLD"
        );
        assert_eq!(
            run(TextOp::ConstantCase, "getHttpResponse"),
            "GET_HTTP_RESPONSE"
        );
        assert_eq!(run(TextOp::PascalCase, ""), "");
    }

    #[test]
    fn lists_move_between_commas_and_lines() {
        assert_eq!(
            apply(&TextOp::CommaToLines, "a, b;c ,, d").unwrap(),
            "a\nb\nc\nd"
        );
        assert_eq!(
            apply(&TextOp::LinesToComma, "a\n\n b \nc").unwrap(),
            "a, b, c"
        );
        assert_eq!(apply(&TextOp::NumberLines, "x\ny").unwrap(), "1. x\n2. y");
    }

    #[test]
    fn shuffling_keeps_every_line_once() {
        let out = apply(&TextOp::ShuffleLines, "a\nb\nc\nd\ne\nf").unwrap();
        let mut got: Vec<&str> = out.lines().collect();
        got.sort();
        assert_eq!(got, vec!["a", "b", "c", "d", "e", "f"]);
        assert_eq!(apply(&TextOp::ShuffleLines, "only").unwrap(), "only");
    }

    #[test]
    fn slugs_are_lower_case_words_with_single_dashes() {
        assert_eq!(
            apply(&TextOp::Slugify, "  Hello,   World! 2026 ").unwrap(),
            "hello-world-2026"
        );
        assert_eq!(apply(&TextOp::Slugify, "Über cool").unwrap(), "über-cool");
        assert_eq!(apply(&TextOp::Slugify, "!!!").unwrap(), "");
    }

    #[test]
    fn tracking_is_cleaned_from_links_inside_text() {
        let text = "See https://example.com/a?utm_source=x&id=7&fbclid=abc. Also https://b.test/?utm_medium=m, ok";
        assert_eq!(
            apply(&TextOp::StripUrlTracking, text).unwrap(),
            "See https://example.com/a?id=7. Also https://b.test/, ok"
        );
        assert_eq!(
            apply(&TextOp::StripUrlTracking, "no links here").unwrap(),
            "no links here"
        );
    }

    #[test]
    fn links_and_emails_can_be_pulled_out_of_text() {
        let text =
            "Mail ann@example.com or visit https://example.com/page, thanks. Also bob@test.org.";
        assert_eq!(
            apply(&TextOp::ExtractUrls, text).unwrap(),
            "https://example.com/page"
        );
        assert_eq!(
            apply(&TextOp::ExtractEmails, text).unwrap(),
            "ann@example.com\nbob@test.org"
        );
        assert!(apply(&TextOp::ExtractUrls, "nothing").is_err());
    }

    #[test]
    fn unix_time_and_dates_convert_both_ways() {
        assert_eq!(
            apply(&TextOp::UnixTimeToDate, "0").unwrap(),
            "1970-01-01 00:00:00 UTC"
        );
        assert_eq!(
            apply(&TextOp::UnixTimeToDate, "1700000000").unwrap(),
            "2023-11-14 22:13:20 UTC"
        );
        assert_eq!(
            apply(&TextOp::UnixTimeToDate, "1700000000000").unwrap(),
            "2023-11-14 22:13:20 UTC",
            "milliseconds are noticed"
        );
        assert_eq!(
            apply(&TextOp::UnixTimeToDate, "-86400").unwrap(),
            "1969-12-31 00:00:00 UTC"
        );
        assert_eq!(
            apply(&TextOp::DateToUnixTime, "2023-11-14 22:13:20").unwrap(),
            "1700000000"
        );
        assert_eq!(
            apply(&TextOp::DateToUnixTime, "2023-11-14T22:13:20Z").unwrap(),
            "1700000000"
        );
        assert_eq!(
            apply(&TextOp::DateToUnixTime, "2000-02-29").unwrap(),
            "951782400"
        );
        assert!(apply(&TextOp::UnixTimeToDate, "abc").is_err());
        assert!(apply(&TextOp::DateToUnixTime, "2023-13-40").is_err());
        assert_eq!(
            apply(&TextOp::UnixTimeToDate, "0\n86400").unwrap(),
            "1970-01-01 00:00:00 UTC\n1970-01-02 00:00:00 UTC"
        );
    }
}
