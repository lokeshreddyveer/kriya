//! Placeholders in text that is inserted for you: dates and times (with offsets), the clipboard, the selection, a cursor
//! position, values you are asked for, and a fresh identifier. Pure: the shell supplies the time and the other values.
//!
//! `{date}` `{date:yyyy-MM-dd}` `{date+7d}` `{date-1M:MMMM d}` `{time}` `{time:hh:mm a}` `{datetime}` `{clipboard}`
//! `{selection}` `{cursor}` `{prompt:Name}` `{uuid}` `{app}` `{newline}` `{tab}`. `{{` and `}}` are literal braces.
//! Anything else in braces is left as it is, so code in a snippet survives.

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PromptValue {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TemplateContext {
    /// Seconds since 1970 (UTC).
    pub now: i64,
    /// The local time zone's offset from UTC, in seconds.
    pub utc_offset_seconds: i32,
    pub clipboard: Option<String>,
    pub selection: Option<String>,
    pub app_name: Option<String>,
    pub uuid: Option<String>,
    pub prompts: Vec<PromptValue>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TemplateOutput {
    pub text: String,
    /// How many characters the cursor should move back from the end after inserting (0 if there is no `{cursor}`).
    pub cursor_back: u32,
    /// Values still needed from the person, in the order they first appear. Ask, then render again with the answers.
    pub prompts_needed: Vec<String>,
}

const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];
const DAYS: [&str; 7] = [
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
];
const MAX_PLACEHOLDER: usize = 80;

// ---- calendar -----------------------------------------------------------------------------------------------------

/// Days since 1970-01-01 for a calendar date (proleptic Gregorian).
pub fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = i64::from((m + 9) % 12);
    let doy = (153 * mp + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn days_in_month(y: i64, m: u32) -> u32 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ => {
            if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 {
                29
            } else {
                28
            }
        }
    }
}

struct Local {
    year: i64,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
    weekday: usize,
    offset: i32,
}

fn local_from(ts: i64, offset: i32) -> Local {
    let t = ts + i64::from(offset);
    let days = t.div_euclid(86_400);
    let secs = t.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    Local {
        year,
        month,
        day,
        hour: (secs / 3600) as u32,
        minute: ((secs % 3600) / 60) as u32,
        second: (secs % 60) as u32,
        weekday: (days + 4).rem_euclid(7) as usize,
        offset,
    }
}

/// Moves a time by an amount: `d` days, `w` weeks, `h` hours, `m` minutes, `M` months, `y` years.
fn shift(ts: i64, offset: i32, amount: i64, unit: char) -> i64 {
    match unit {
        'd' => ts + amount * 86_400,
        'w' => ts + amount * 7 * 86_400,
        'h' => ts + amount * 3600,
        'm' => ts + amount * 60,
        'M' | 'y' => {
            let l = local_from(ts, offset);
            let months = if unit == 'y' { amount * 12 } else { amount };
            let total = l.year * 12 + i64::from(l.month) - 1 + months;
            let (year, month) = (total.div_euclid(12), (total.rem_euclid(12) + 1) as u32);
            let day = l.day.min(days_in_month(year, month));
            let tod = i64::from(l.hour) * 3600 + i64::from(l.minute) * 60 + i64::from(l.second);
            days_from_civil(year, month, day) * 86_400 + tod - i64::from(offset)
        }
        _ => ts,
    }
}

/// Formats a time with letters like `yyyy-MM-dd HH:mm`. `'text'` in quotes is copied as it is.
pub fn format_time(ts: i64, offset: i32, format: &str) -> String {
    let l = local_from(ts, offset);
    let chars: Vec<char> = format.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '\'' {
            i += 1;
            while i < chars.len() && chars[i] != '\'' {
                out.push(chars[i]);
                i += 1;
            }
            i += 1;
            continue;
        }
        if !"yMdEHhmsaZ".contains(c) {
            out.push(c);
            i += 1;
            continue;
        }
        let mut n = 0;
        while i < chars.len() && chars[i] == c {
            n += 1;
            i += 1;
        }
        let hour12 = if l.hour.is_multiple_of(12) {
            12
        } else {
            l.hour % 12
        };
        match c {
            'y' => out.push_str(&if n == 2 {
                format!("{:02}", l.year.rem_euclid(100))
            } else {
                format!("{:0n$}", l.year, n = n.max(1))
            }),
            'M' => out.push_str(&match n {
                1 => l.month.to_string(),
                2 => format!("{:02}", l.month),
                3 => MONTHS[l.month as usize - 1][..3].to_string(),
                _ => MONTHS[l.month as usize - 1].to_string(),
            }),
            'd' => out.push_str(&if n >= 2 {
                format!("{:02}", l.day)
            } else {
                l.day.to_string()
            }),
            'E' => out.push_str(&if n >= 4 {
                DAYS[l.weekday].to_string()
            } else {
                DAYS[l.weekday][..3].to_string()
            }),
            'H' => out.push_str(&if n >= 2 {
                format!("{:02}", l.hour)
            } else {
                l.hour.to_string()
            }),
            'h' => out.push_str(&if n >= 2 {
                format!("{hour12:02}")
            } else {
                hour12.to_string()
            }),
            'm' => out.push_str(&if n >= 2 {
                format!("{:02}", l.minute)
            } else {
                l.minute.to_string()
            }),
            's' => out.push_str(&if n >= 2 {
                format!("{:02}", l.second)
            } else {
                l.second.to_string()
            }),
            'a' => out.push_str(if l.hour < 12 { "AM" } else { "PM" }),
            _ => {
                let sign = if l.offset < 0 { '-' } else { '+' };
                let abs = l.offset.unsigned_abs();
                out.push_str(&format!("{sign}{:02}{:02}", abs / 3600, (abs % 3600) / 60));
            }
        }
    }
    out
}

// ---- rendering -------------------------------------------------------------------------------------------------------

/// Fills in a template. Call it once to find out which `{prompt:…}` values are needed, then again with the answers.
pub fn render_template(body: &str, ctx: &TemplateContext) -> TemplateOutput {
    let chars: Vec<char> = body.chars().collect();
    let mut out = String::new();
    let mut cursor_at: Option<usize> = None;
    let mut needed: Vec<String> = Vec::new();
    // `}}` collapses to one brace only after a `{{`, so a closing `}}` in code (JSON, for one) stays as it is.
    let mut escaped_open = 0usize;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '{' && chars.get(i + 1) == Some(&'{') {
            out.push('{');
            escaped_open += 1;
            i += 2;
            continue;
        }
        if c == '}' && chars.get(i + 1) == Some(&'}') && escaped_open > 0 {
            out.push('}');
            escaped_open -= 1;
            i += 2;
            continue;
        }
        if c == '{' {
            let end = chars[i + 1..]
                .iter()
                .take(MAX_PLACEHOLDER)
                .position(|x| *x == '}');
            if let Some(len) = end {
                let inner: String = chars[i + 1..i + 1 + len].iter().collect();
                if let Some(replacement) = expand(&inner, ctx, &mut needed) {
                    match replacement {
                        Piece::Text(t) => out.push_str(&t),
                        Piece::Cursor => {
                            if cursor_at.is_none() {
                                cursor_at = Some(out.chars().count());
                            }
                        }
                    }
                    i += len + 2;
                    continue;
                }
            }
        }
        out.push(c);
        i += 1;
    }
    let total = out.chars().count();
    TemplateOutput {
        text: out,
        cursor_back: cursor_at.map_or(0, |at| (total - at) as u32),
        prompts_needed: needed,
    }
}

enum Piece {
    Text(String),
    Cursor,
}

fn expand(inner: &str, ctx: &TemplateContext, needed: &mut Vec<String>) -> Option<Piece> {
    let name: String = inner.chars().take_while(char::is_ascii_lowercase).collect();
    let rest = &inner[name.len()..];
    let text = |s: String| Some(Piece::Text(s));
    match name.as_str() {
        "date" | "time" | "datetime" => {
            let (offset_part, format_part) = match rest.split_once(':') {
                Some((o, f)) => (o, Some(f)),
                None => (rest, None),
            };
            let ts = if offset_part.is_empty() {
                ctx.now
            } else {
                apply_offset(ctx.now, ctx.utc_offset_seconds, offset_part)?
            };
            let default = match name.as_str() {
                "date" => "yyyy-MM-dd",
                "time" => "HH:mm",
                _ => "yyyy-MM-dd HH:mm",
            };
            text(format_time(
                ts,
                ctx.utc_offset_seconds,
                format_part.filter(|f| !f.is_empty()).unwrap_or(default),
            ))
        }
        "clipboard" if rest.is_empty() => text(ctx.clipboard.clone().unwrap_or_default()),
        "selection" if rest.is_empty() => text(ctx.selection.clone().unwrap_or_default()),
        "app" if rest.is_empty() => text(ctx.app_name.clone().unwrap_or_default()),
        "uuid" if rest.is_empty() => text(ctx.uuid.clone().unwrap_or_default()),
        "newline" if rest.is_empty() => text("\n".into()),
        "tab" if rest.is_empty() => text("\t".into()),
        "cursor" if rest.is_empty() => Some(Piece::Cursor),
        "prompt" => {
            let label = rest.strip_prefix(':')?.trim();
            if label.is_empty() {
                return None;
            }
            match ctx.prompts.iter().find(|p| p.name == label) {
                Some(p) => text(p.value.clone()),
                None => {
                    if !needed.iter().any(|n| n == label) {
                        needed.push(label.to_string());
                    }
                    text(String::new())
                }
            }
        }
        _ => None,
    }
}

/// `+3d`, `-1M`, `+2h`, `+90m`, `+1y`. `None` if it is not one of those.
fn apply_offset(ts: i64, utc_offset: i32, part: &str) -> Option<i64> {
    let mut chars = part.chars();
    let sign = match chars.next()? {
        '+' => 1,
        '-' => -1,
        _ => return None,
    };
    let rest: String = chars.collect();
    let unit = rest.chars().last()?;
    if !"dwhmMy".contains(unit) {
        return None;
    }
    let digits = &rest[..rest.len() - unit.len_utf8()];
    let n: i64 = digits.parse().ok()?;
    if digits.is_empty() || n > 100_000 {
        return None;
    }
    Some(shift(ts, utc_offset, sign * n, unit))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(y: i64, mo: u32, d: u32, h: i64, mi: i64, s: i64) -> i64 {
        days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + s
    }

    fn ctx(now: i64) -> TemplateContext {
        TemplateContext {
            now,
            utc_offset_seconds: 0,
            clipboard: Some("CLIP".into()),
            selection: Some("SEL".into()),
            app_name: Some("Notes".into()),
            uuid: Some("1234".into()),
            prompts: vec![],
        }
    }

    fn render(body: &str, c: &TemplateContext) -> String {
        render_template(body, c).text
    }

    #[test]
    fn calendar_maths_round_trips() {
        for days in [-1000, -1, 0, 1, 365, 19_797, 20_000, 80_000] {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, m, d), days);
        }
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(days_from_civil(2024, 2, 29)), (2024, 2, 29));
    }

    #[test]
    fn dates_and_times_use_sensible_defaults() {
        let c = ctx(at(2024, 3, 15, 13, 45, 9));
        assert_eq!(render("{date}", &c), "2024-03-15");
        assert_eq!(render("{time}", &c), "13:45");
        assert_eq!(render("{datetime}", &c), "2024-03-15 13:45");
    }

    #[test]
    fn formats_cover_names_clock_styles_and_literals() {
        let c = ctx(at(2024, 3, 5, 13, 5, 9));
        assert_eq!(
            render("{date:EEEE, MMMM d, yyyy}", &c),
            "Tuesday, March 5, 2024"
        );
        assert_eq!(render("{date:EEE MMM dd yy}", &c), "Tue Mar 05 24");
        assert_eq!(render("{time:hh:mm a}", &c), "01:05 PM");
        assert_eq!(render("{time:h:mm:ss a}", &c), "1:05:09 PM");
        assert_eq!(render("{date:yyyy'年'M'月'}", &c), "2024年3月");
        assert_eq!(render("{time:HH:mm Z}", &c), "13:05 +0000");
        let midnight = ctx(at(2024, 3, 5, 0, 0, 0));
        assert_eq!(render("{time:h a}", &midnight), "12 AM");
    }

    #[test]
    fn the_time_zone_shifts_the_clock_and_the_date() {
        let mut c = ctx(at(2024, 3, 15, 23, 30, 0));
        c.utc_offset_seconds = 2 * 3600 + 30 * 60;
        assert_eq!(
            render("{date} {time:HH:mm Z}", &c),
            "2024-03-16 02:00 +0230"
        );
        c.utc_offset_seconds = -5 * 3600;
        assert_eq!(render("{time:HH:mm Z}", &c), "18:30 -0500");
    }

    #[test]
    fn offsets_move_days_weeks_hours_minutes_months_and_years() {
        let c = ctx(at(2024, 1, 31, 10, 0, 0));
        assert_eq!(render("{date+7d}", &c), "2024-02-07");
        assert_eq!(render("{date+2w}", &c), "2024-02-14");
        assert_eq!(render("{date-1d}", &c), "2024-01-30");
        assert_eq!(
            render("{date+1M}", &c),
            "2024-02-29",
            "the day is kept inside the month"
        );
        assert_eq!(render("{date-2M}", &c), "2023-11-30");
        assert_eq!(render("{date+1y}", &c), "2025-01-31");
        assert_eq!(render("{time+90m}", &c), "11:30");
        assert_eq!(render("{time-10h}", &c), "00:00");
        assert_eq!(render("{date+3d:EEE d MMM}", &c), "Sat 3 Feb");
        assert_eq!(
            render("{date+1}", &c),
            "{date+1}",
            "a bad offset is left as typed"
        );
        assert_eq!(render("{date+xd}", &c), "{date+xd}");
    }

    #[test]
    fn leap_years_and_year_ends_work() {
        assert_eq!(
            render("{date}", &ctx(at(2024, 12, 31, 23, 59, 59))),
            "2024-12-31"
        );
        assert_eq!(
            render("{date+1d}", &ctx(at(2024, 12, 31, 23, 59, 59))),
            "2025-01-01"
        );
        assert_eq!(
            render("{date+1d}", &ctx(at(2024, 2, 28, 0, 0, 0))),
            "2024-02-29"
        );
        assert_eq!(
            render("{date+1d}", &ctx(at(2023, 2, 28, 0, 0, 0))),
            "2023-03-01"
        );
        assert_eq!(
            render("{date:yyyy}", &ctx(at(1969, 7, 20, 20, 17, 0))),
            "1969"
        );
    }

    #[test]
    fn clipboard_selection_app_and_identifiers() {
        let c = ctx(0);
        assert_eq!(
            render("Hi {clipboard}, {selection} in {app} #{uuid}", &c),
            "Hi CLIP, SEL in Notes #1234"
        );
        let empty = TemplateContext {
            clipboard: None,
            selection: None,
            app_name: None,
            uuid: None,
            ..ctx(0)
        };
        assert_eq!(render("[{clipboard}{selection}{app}{uuid}]", &empty), "[]");
        assert_eq!(render("a{newline}b{tab}c", &c), "a\nb\tc");
    }

    #[test]
    fn the_cursor_marks_where_typing_continues() {
        let out = render_template("Dear {cursor},\nRegards", &ctx(0));
        assert_eq!(out.text, "Dear ,\nRegards");
        assert_eq!(out.cursor_back, ",\nRegards".chars().count() as u32);
        assert_eq!(render_template("{cursor}end", &ctx(0)).cursor_back, 3);
        assert_eq!(render_template("no cursor", &ctx(0)).cursor_back, 0);
        assert_eq!(
            render_template("a{cursor}b{cursor}c", &ctx(0)).cursor_back,
            2,
            "only the first counts"
        );
        assert_eq!(
            render_template("é{cursor}日本", &ctx(0)).cursor_back,
            2,
            "counted in characters, not bytes"
        );
    }

    #[test]
    fn prompts_are_collected_once_then_filled() {
        let first = render_template("To {prompt:Name} from {prompt:Me}: {prompt:Name}!", &ctx(0));
        assert_eq!(
            first.prompts_needed,
            vec!["Name".to_string(), "Me".to_string()]
        );
        assert_eq!(first.text, "To  from : !");
        let mut c = ctx(0);
        c.prompts = vec![
            PromptValue {
                name: "Name".into(),
                value: "Ada".into(),
            },
            PromptValue {
                name: "Me".into(),
                value: "Bob".into(),
            },
        ];
        let second = render_template("To {prompt:Name} from {prompt:Me}: {prompt:Name}!", &c);
        assert_eq!(second.text, "To Ada from Bob: Ada!");
        assert!(second.prompts_needed.is_empty());
        assert_eq!(render("{prompt:}", &ctx(0)), "{prompt:}");
        assert_eq!(
            render_template("{prompt:Full name}", &ctx(0)).prompts_needed,
            vec!["Full name".to_string()]
        );
    }

    #[test]
    fn braces_that_are_not_placeholders_survive() {
        let c = ctx(0);
        assert_eq!(
            render("function() { return 1; }", &c),
            "function() { return 1; }"
        );
        assert_eq!(render("{{date}} is literal", &c), "{date} is literal");
        assert_eq!(
            render("{unknown} {Date} {date", &c),
            "{unknown} {Date} {date"
        );
        assert_eq!(render("{{}}", &c), "{}");
        assert_eq!(
            render("json: {\"a\": {\"b\": 1}}", &c),
            "json: {\"a\": {\"b\": 1}}"
        );
        assert_eq!(render("{clipboardx}", &c), "{clipboardx}");
    }

    #[test]
    fn a_runaway_brace_does_not_swallow_the_text() {
        let long = format!("{{{} and more", "x".repeat(200));
        assert_eq!(render(&long, &ctx(0)), long);
    }
}
