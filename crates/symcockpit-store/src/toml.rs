//! The deliberately small TOML subset the Swift core reads (`TOMLParser.swift`):
//! `[section]` headers, `key = value`, `#` comments, quoted/bare strings,
//! integers, doubles, booleans and inline arrays. Anything else is skipped
//! line by line, never an error, so one bad line cannot hide the rest.

use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    String(String),
    Integer(i64),
    Double(f64),
    Boolean(bool),
    Array(Vec<Value>),
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_int(&self) -> Option<i64> {
        match self {
            Value::Integer(i) => Some(*i),
            _ => None,
        }
    }

    pub fn as_double(&self) -> Option<f64> {
        match self {
            Value::Double(d) => Some(*d),
            Value::Integer(i) => Some(*i as f64),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Boolean(b) => Some(*b),
            _ => None,
        }
    }
}

/// Sections map to key/value maps; keys before any header live under `""`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Table(pub BTreeMap<String, BTreeMap<String, Value>>);

impl Table {
    pub fn get(&self, section: &str, key: &str) -> Option<&Value> {
        self.0.get(section)?.get(key)
    }
}

fn is_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

fn trim(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() && !is_newline(c))
}

/// Drops a trailing `# comment`, honouring quotes and backslash escapes.
fn strip_comment(line: &str) -> &str {
    let (mut single, mut double, mut escaped) = (false, false, false);
    for (i, ch) in line.char_indices() {
        if escaped {
            escaped = false;
        } else if ch == '\\' && (single || double) {
            escaped = true;
        } else if ch == '\'' && !double {
            single = !single;
        } else if ch == '"' && !single {
            double = !double;
        } else if ch == '#' && !single && !double {
            return &line[..i];
        }
    }
    line
}

fn parse_value(raw: &str) -> Option<Value> {
    let t = trim(raw);
    if t.is_empty() {
        return None;
    }
    match t.to_lowercase().as_str() {
        "true" => return Some(Value::Boolean(true)),
        "false" => return Some(Value::Boolean(false)),
        _ => {}
    }
    let quoted = |q: char| t.chars().count() >= 2 && t.starts_with(q) && t.ends_with(q);
    if quoted('"') || quoted('\'') {
        return Some(Value::String(t[1..t.len() - 1].to_owned()));
    }
    if t.starts_with('[') && t.ends_with(']') {
        let inner = trim(&t[1..t.len() - 1]);
        if inner.is_empty() {
            return Some(Value::Array(Vec::new()));
        }
        return Some(Value::Array(
            split_array(inner)
                .iter()
                .filter_map(|e| parse_value(e))
                .collect(),
        ));
    }
    if let Ok(i) = t.parse::<i64>() {
        return Some(Value::Integer(i));
    }
    if let Ok(d) = t.parse::<f64>() {
        return Some(Value::Double(d));
    }
    // Bare strings are not standard TOML but the Swift parser accepts them.
    Some(Value::String(t.to_owned()))
}

fn split_array(body: &str) -> Vec<String> {
    let mut elements = Vec::new();
    let mut current = String::new();
    let (mut depth, mut single, mut double, mut escaped) = (0i32, false, false, false);
    for ch in body.chars() {
        if escaped {
            escaped = false;
        } else if ch == '\\' && (single || double) {
            escaped = true;
        } else if ch == '\'' && !double {
            single = !single;
        } else if ch == '"' && !single {
            double = !double;
        } else if !single && !double {
            match ch {
                '[' => depth += 1,
                ']' => depth -= 1,
                ',' if depth == 0 => {
                    elements.push(trim(&current).to_owned());
                    current.clear();
                    continue;
                }
                _ => {}
            }
        }
        current.push(ch);
    }
    let last = trim(&current);
    if !last.is_empty() {
        elements.push(last.to_owned());
    }
    elements
}

pub fn parse(input: &str) -> Table {
    let mut sections: BTreeMap<String, BTreeMap<String, Value>> = BTreeMap::new();
    let mut current = String::new();
    for raw_line in input.split(is_newline) {
        let line = trim(strip_comment(raw_line));
        if line.is_empty() {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') && !line.starts_with("[[") {
            current = trim(&line[1..line.len() - 1]).to_owned();
            sections.entry(current.clone()).or_default();
            continue;
        }
        let Some(eq) = line.find('=') else { continue };
        let key = trim(&line[..eq]);
        let Some(value) = parse_value(&line[eq + 1..]) else {
            continue;
        };
        if key.is_empty() {
            continue;
        }
        sections
            .entry(current.clone())
            .or_default()
            .insert(key.to_owned(), value);
    }
    Table(sections)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Cases below are ported from `TOMLParserTests` in
    // tuning/Tests/SymCockpitCoreTests/ConfigTests.swift.

    #[test]
    fn empty_and_comment_only_inputs() {
        assert!(parse("").0.is_empty());
        assert!(parse("# just a comment\n# another").0.is_empty());
    }

    #[test]
    fn sections_root_keys_and_value_types() {
        let t = parse(
            "name = \"symtune\"\nversion = 1\n[s]\nq = 'w'\nn = -7\npi = 3.25\non = true\nOFF = False\n",
        );
        assert_eq!(t.get("", "name").unwrap().as_str(), Some("symtune"));
        assert_eq!(t.get("", "version").unwrap().as_int(), Some(1));
        assert_eq!(t.get("s", "q").unwrap().as_str(), Some("w"));
        assert_eq!(t.get("s", "n").unwrap().as_int(), Some(-7));
        assert_eq!(t.get("s", "pi").unwrap().as_double(), Some(3.25));
        assert_eq!(t.get("s", "on").unwrap().as_bool(), Some(true));
        assert_eq!(t.get("s", "OFF").unwrap().as_bool(), Some(false));
        // Integers read as doubles, doubles never as integers.
        assert_eq!(
            parse("[s]\nk = 2").get("s", "k").unwrap().as_double(),
            Some(2.0)
        );
        assert_eq!(parse("[s]\nk = 2.5").get("s", "k").unwrap().as_int(), None);
    }

    #[test]
    fn comments_inline_and_inside_strings() {
        let t = parse("# c\n[x]\nkey = 42 # the answer\ns = \"value # not a comment\"\n");
        assert_eq!(t.get("x", "key").unwrap().as_int(), Some(42));
        assert_eq!(
            t.get("x", "s").unwrap().as_str(),
            Some("value # not a comment")
        );
    }

    #[test]
    fn duplicate_sections_merge_and_empty_sections_exist() {
        let t = parse("[s]\na = 1\n[s]\nb = 2\n[empty]\n");
        assert_eq!(t.get("s", "a").unwrap().as_int(), Some(1));
        assert_eq!(t.get("s", "b").unwrap().as_int(), Some(2));
        assert!(t.0["empty"].is_empty());
    }

    #[test]
    fn malformed_lines_are_skipped() {
        let t = parse(
            "  [  s  ]  \n  key  =  42  \nno_equals\nkey2 =\nvalid = 1\n[[not_a_section]]\nk = 1\n",
        );
        assert_eq!(t.get("s", "key").unwrap().as_int(), Some(42));
        assert_eq!(t.get("s", "valid").unwrap().as_int(), Some(1));
        assert!(t.get("s", "key2").is_none());
        // `[[x]]` is not a section header and has no `=`; later keys stay in `s`.
        assert_eq!(t.get("s", "k").unwrap().as_int(), Some(1));
        assert!(!t.0.contains_key("[not_a_section]"));
    }

    #[test]
    fn arrays_split_on_top_level_commas_only() {
        let t = parse("[m]\na = [\"cpu\", 'memory', 3]\nb = []\nc = [\"x,y\", \"z\"]\n");
        assert_eq!(
            t.get("m", "a").unwrap(),
            &Value::Array(vec![
                Value::String("cpu".into()),
                Value::String("memory".into()),
                Value::Integer(3)
            ])
        );
        assert_eq!(t.get("m", "b").unwrap(), &Value::Array(vec![]));
        assert_eq!(
            t.get("m", "c").unwrap(),
            &Value::Array(vec![Value::String("x,y".into()), Value::String("z".into())])
        );
    }

    #[test]
    fn bare_strings_are_accepted() {
        assert_eq!(
            parse("[g]\nm = read-only").get("g", "m").unwrap().as_str(),
            Some("read-only")
        );
    }
}
