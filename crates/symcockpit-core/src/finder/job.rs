//! The job file: the only thing that crosses from the extension into the app. Parsing is
//! strict, because the writer is a sandboxed extension and the file sits in a directory other
//! processes of the same user can write to.

use serde_json::Value;
use symcockpit_contract::areas::finder::{ACTIONS, JOB_TTL_SECS, JOB_VERSION};

/// Larger files are not read at all.
pub const MAX_JOB_BYTES: usize = 256 * 1024;
const MAX_PATHS: usize = 1000;
/// A writer's clock may run slightly ahead of ours.
const CLOCK_SKEW_SECS: i64 = 5;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Action {
    CopyPath,
    NewFile,
    OpenInTerminal,
}

impl Action {
    pub fn id(self) -> &'static str {
        match self {
            Action::CopyPath => ACTIONS[0],
            Action::NewFile => ACTIONS[1],
            Action::OpenInTerminal => ACTIONS[2],
        }
    }

    fn parse(id: &str) -> Option<Action> {
        [Action::CopyPath, Action::NewFile, Action::OpenInTerminal]
            .into_iter()
            .find(|a| a.id() == id)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Job {
    pub id: String,
    pub action: Action,
    pub paths: Vec<String>,
    pub created_at: i64,
    pub expires_at: i64,
}

/// Why a job was refused; the text goes into the result file.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Reject {
    TooLarge,
    Malformed(String),
    Version(i64),
    UnknownAction(String),
    BadPath(String),
    /// The job names an id other than its file name.
    IdMismatch,
    Expired,
    Duplicate,
}

impl std::fmt::Display for Reject {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Reject::TooLarge => f.write_str("job file too large"),
            Reject::Malformed(why) => write!(f, "malformed job: {why}"),
            Reject::Version(v) => write!(f, "unsupported job version {v}"),
            Reject::UnknownAction(a) => write!(f, "unknown action {a:?}"),
            Reject::BadPath(why) => write!(f, "bad path: {why}"),
            Reject::IdMismatch => f.write_str("job id does not match its file name"),
            Reject::Expired => f.write_str("job expired"),
            Reject::Duplicate => f.write_str("duplicate job"),
        }
    }
}

/// 36 characters, lowercase hex in 8-4-4-4-12 groups.
pub fn is_job_id(s: &str) -> bool {
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => b == b'-',
            _ => b.is_ascii_digit() || (b'a'..=b'f').contains(&b),
        })
}

/// A random version 4 id in the same shape the extension writes.
pub fn new_job_id() -> String {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).expect("system random source");
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let hex: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

/// Validates `bytes` read from `<file_id>.json` at time `now` (epoch seconds).
pub fn parse_job(file_id: &str, bytes: &[u8], now: i64) -> Result<Job, Reject> {
    if bytes.len() > MAX_JOB_BYTES {
        return Err(Reject::TooLarge);
    }
    let v: Value = serde_json::from_slice(bytes).map_err(|e| Reject::Malformed(e.to_string()))?;
    let int = |k: &str| {
        v.get(k)
            .and_then(Value::as_i64)
            .ok_or_else(|| Reject::Malformed(format!("{k} missing or not an integer")))
    };
    let string = |k: &str| {
        v.get(k)
            .and_then(Value::as_str)
            .ok_or_else(|| Reject::Malformed(format!("{k} missing or not a string")))
    };
    let version = int("version")?;
    if version != i64::from(JOB_VERSION) {
        return Err(Reject::Version(version));
    }
    let id = string("id")?;
    if !is_job_id(id) {
        return Err(Reject::Malformed("id is not a lowercase uuid".into()));
    }
    if id != file_id {
        return Err(Reject::IdMismatch);
    }
    let action_id = string("action")?;
    let action = Action::parse(action_id).ok_or_else(|| Reject::UnknownAction(action_id.into()))?;
    let (created_at, expires_at) = (int("created_at")?, int("expires_at")?);
    if expires_at < created_at || expires_at - created_at > JOB_TTL_SECS {
        return Err(Reject::Malformed("lifetime longer than allowed".into()));
    }
    let list = v
        .get("paths")
        .and_then(Value::as_array)
        .ok_or_else(|| Reject::Malformed("paths missing".into()))?;
    if list.is_empty() || list.len() > MAX_PATHS {
        return Err(Reject::BadPath(format!("{} paths", list.len())));
    }
    let mut paths = Vec::with_capacity(list.len());
    for p in list {
        let p = p
            .as_str()
            .ok_or_else(|| Reject::BadPath("not a string".into()))?;
        if !p.starts_with('/') || p.contains('\0') {
            return Err(Reject::BadPath("must be absolute and free of NUL".into()));
        }
        paths.push(p.to_owned());
    }
    if created_at > now + CLOCK_SKEW_SECS || now > expires_at {
        return Err(Reject::Expired);
    }
    Ok(Job {
        id: id.to_owned(),
        action,
        paths,
        created_at,
        expires_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0b9d7c1e-4f4a-4d6e-9a0f-1c2d3e4f5a6b";

    fn job(extra: &str) -> Vec<u8> {
        format!(
            r#"{{"version":1,"id":"{ID}","action":"copy_path","paths":["/tmp/a b"],"created_at":1000,"expires_at":1060{extra}}}"#
        )
        .into_bytes()
    }

    #[test]
    fn a_fresh_job_parses_and_expiry_is_inclusive() {
        let j = parse_job(ID, &job(""), 1000).unwrap();
        assert_eq!(j.action, Action::CopyPath);
        assert_eq!(j.paths, ["/tmp/a b"]);
        assert!(parse_job(ID, &job(""), 1060).is_ok());
        assert_eq!(parse_job(ID, &job(""), 1061), Err(Reject::Expired));
    }

    #[test]
    fn rejections_are_specific() {
        let bad = |bytes: &[u8]| parse_job(ID, bytes, 1000).unwrap_err();
        assert!(matches!(bad(b"{nope"), Reject::Malformed(_)));
        assert!(matches!(
            bad(&job("").replace_range_bytes("\"version\":1", "\"version\":2")),
            Reject::Version(2)
        ));
        assert!(matches!(
            bad(&job("").replace_range_bytes("copy_path", "rm_rf")),
            Reject::UnknownAction(_)
        ));
        assert!(matches!(
            bad(&job("").replace_range_bytes("/tmp/a b", "relative")),
            Reject::BadPath(_)
        ));
        assert!(matches!(
            bad(&job("").replace_range_bytes("1060", "5000")),
            Reject::Malformed(_)
        ));
        assert_eq!(
            parse_job("ffffffff-4f4a-4d6e-9a0f-1c2d3e4f5a6b", &job(""), 1000),
            Err(Reject::IdMismatch)
        );
        assert_eq!(
            parse_job(ID, &vec![b' '; MAX_JOB_BYTES + 1], 1000),
            Err(Reject::TooLarge)
        );
        // Created in the future beyond the skew allowance.
        assert_eq!(parse_job(ID, &job(""), 900), Err(Reject::Expired));
    }

    trait Replace {
        fn replace_range_bytes(self, from: &str, to: &str) -> Vec<u8>;
    }
    impl Replace for Vec<u8> {
        fn replace_range_bytes(self, from: &str, to: &str) -> Vec<u8> {
            String::from_utf8(self)
                .unwrap()
                .replace(from, to)
                .into_bytes()
        }
    }

    #[test]
    fn ids_are_validated_and_generated_in_the_same_shape() {
        assert!(is_job_id(ID));
        assert!(!is_job_id(&ID.to_uppercase()));
        assert!(!is_job_id("../../etc/passwd"));
        let a = new_job_id();
        assert!(is_job_id(&a));
        assert_ne!(a, new_job_id());
    }
}
