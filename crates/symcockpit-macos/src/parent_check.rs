//! Parent check of the app agent (architecture §8, §10): `symcockpit agent`
//! serves only a parent process that is the signed Cockpit app.
//!
//! The check is a code-signing requirement evaluated against the parent's
//! running code (Security.framework). It is the app side of the same trust
//! root as the fan helper's `CodeSigningRequirements` (Swift): Developer ID
//! chain, the app's bundle identifier, one team, and no hardened-runtime
//! escape entitlement. The team is baked into the build (`SYMCOCKPIT_TEAM_ID`,
//! the same value as `EXPECTED_TEAM_ID` of `scripts/build-app.sh`) and never
//! read from this binary's own signature or the environment: a binary swapped
//! for one signed by another Developer ID must not vouch for its own parent.
//!
//! shortcut: the parent is identified by PID (`SecCodeCopyGuestWithAttributes`
//! with `kSecGuestAttributePid`), not by audit token, which a child cannot
//! obtain for its parent; the PID is re-read after the check and must not have
//! changed. Upgrade if a PID-reuse attack on the parent shows up in the threat
//! model.

use core_foundation::base::{CFType, TCFType};
use core_foundation::dictionary::CFDictionary;
use core_foundation::number::CFNumber;
use core_foundation::string::CFString;
use core_foundation_sys::base::{CFTypeRef, OSStatus};
use core_foundation_sys::dictionary::CFDictionaryRef;
use core_foundation_sys::string::CFStringRef;

/// Bundle identifier the app is signed with (`scripts/build-app.sh`,
/// `FanHelperConstants.appIdentifier`).
pub const APP_IDENTIFIER: &str = "com.symaira.cockpit";

/// Entitlements that defeat the hardened runtime
/// (`CodeSigningRequirements.forbiddenEntitlements`).
pub const FORBIDDEN_ENTITLEMENTS: [&str; 4] = [
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.allow-jit",
];

/// A reason the parent is not acceptable. Each text is a complete stderr line.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ParentError {
    /// No team baked into this build.
    NoTeam,
    /// The team identifier is not ten upper-case alphanumerics.
    BadTeam(String),
    /// The parent does not satisfy the requirement (unsigned, ad-hoc, other
    /// team or other identifier).
    Unsigned(String),
    /// The parent changed while it was being checked.
    ParentChanged,
}

impl std::fmt::Display for ParentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoTeam => f.write_str(
                "this build carries no team identifier (SYMCOCKPIT_TEAM_ID was not set at build time)",
            ),
            Self::BadTeam(team) => write!(f, "invalid team identifier {team:?}"),
            Self::Unsigned(detail) => write!(
                f,
                "the parent process is not the signed {APP_IDENTIFIER} app ({detail})"
            ),
            Self::ParentChanged => f.write_str("the parent process changed during the check"),
        }
    }
}

impl std::error::Error for ParentError {}

/// What the check needs from the platform; a fake in tests.
pub trait CodeSignature {
    fn parent_pid(&self) -> u32;
    /// Whether the running code of `pid` satisfies `requirement`.
    /// `Err` is the platform's reason (also for "not signed at all").
    fn satisfies(&self, pid: u32, requirement: &str) -> Result<(), String>;
}

/// The requirement the parent must meet. `team` must be validated first.
pub fn requirement(team: &str) -> String {
    let denied = FORBIDDEN_ENTITLEMENTS
        .iter()
        .map(|e| format!("!entitlement[\"{e}\"] exists"))
        .collect::<Vec<_>>()
        .join(" and ");
    format!(
        "anchor apple generic and identifier \"{APP_IDENTIFIER}\" \
         and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
         and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
         and certificate leaf[subject.OU] = \"{team}\" and {denied}"
    )
}

fn valid_team(team: &str) -> bool {
    team.len() == 10
        && team
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
}

/// Accepts the parent only when it is the Cockpit app signed by the baked
/// team. The team is validated before it goes into the requirement text.
pub fn check_parent(sig: &dyn CodeSignature, baked_team: Option<&str>) -> Result<(), ParentError> {
    let team = baked_team.ok_or(ParentError::NoTeam)?;
    if !valid_team(team) {
        return Err(ParentError::BadTeam(team.to_owned()));
    }
    let pid = sig.parent_pid();
    sig.satisfies(pid, &requirement(team))
        .map_err(ParentError::Unsigned)?;
    if sig.parent_pid() != pid {
        return Err(ParentError::ParentChanged);
    }
    Ok(())
}

// --------------------------------------------------------------- Security.framework

type SecCodeRef = CFTypeRef;
type SecRequirementRef = CFTypeRef;

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    static kSecGuestAttributePid: CFStringRef;
    fn SecCodeCopyGuestWithAttributes(
        host: SecCodeRef,
        attributes: CFDictionaryRef,
        flags: u32,
        guest: *mut SecCodeRef,
    ) -> OSStatus;
    fn SecRequirementCreateWithString(
        text: CFStringRef,
        flags: u32,
        out: *mut SecRequirementRef,
    ) -> OSStatus;
    fn SecCodeCheckValidity(
        code: SecCodeRef,
        flags: u32,
        requirement: SecRequirementRef,
    ) -> OSStatus;
}

/// Takes ownership of a +1 reference returned by a `Copy`/`Create` function.
fn owned(status: OSStatus, reference: CFTypeRef, what: &str) -> Result<CFType, String> {
    if status != 0 || reference.is_null() {
        return Err(format!("{what} failed (OSStatus {status})"));
    }
    // SAFETY: the pointer is non-null and was returned under the create rule
    // (+1) by a Security function that reported success.
    Ok(unsafe { CFType::wrap_under_create_rule(reference) })
}

/// The real Security.framework implementation.
pub struct SystemSignature;

impl CodeSignature for SystemSignature {
    fn parent_pid(&self) -> u32 {
        // SAFETY: getppid has no preconditions.
        unsafe { libc::getppid() }.unsigned_abs()
    }

    fn satisfies(&self, pid: u32, requirement: &str) -> Result<(), String> {
        let pid = i32::try_from(pid).map_err(|_| "pid out of range".to_owned())?;
        // SAFETY: a framework constant, valid for the process lifetime.
        let key = unsafe { CFString::wrap_under_get_rule(kSecGuestAttributePid) };
        let attributes = CFDictionary::from_CFType_pairs(&[(key, CFNumber::from(pid))]);
        let mut guest: SecCodeRef = std::ptr::null();
        // SAFETY: a null host means the system's; `attributes` is a live dictionary.
        let status = unsafe {
            SecCodeCopyGuestWithAttributes(
                std::ptr::null(),
                attributes.as_concrete_TypeRef() as CFDictionaryRef,
                0,
                &mut guest,
            )
        };
        let guest = owned(status, guest, "looking up the parent's code")?;
        let text = CFString::new(requirement);
        let mut compiled: SecRequirementRef = std::ptr::null();
        // SAFETY: `text` is a live CFString; `compiled` is a valid out-pointer.
        let status =
            unsafe { SecRequirementCreateWithString(text.as_concrete_TypeRef(), 0, &mut compiled) };
        let compiled = owned(status, compiled, "compiling the requirement")?;
        // SAFETY: both arguments are live Security objects.
        let status =
            unsafe { SecCodeCheckValidity(guest.as_CFTypeRef(), 0, compiled.as_CFTypeRef()) };
        match status {
            0 => Ok(()),
            // errSecCSUnsigned / errSecCSReqFailed / errSecCSSignatureFailed ...
            code => Err(format!("signature check failed (OSStatus {code})")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEAM: &str = "ABCDE12345";

    /// A signature port that accepts exactly one (identifier, team) pair, the
    /// way the requirement text spells it.
    struct Fake {
        parent_team: Option<&'static str>,
        parent_id: &'static str,
        pids: std::cell::RefCell<Vec<u32>>,
    }

    impl Fake {
        fn new(parent_team: Option<&'static str>) -> Self {
            Self {
                parent_team,
                parent_id: APP_IDENTIFIER,
                pids: std::cell::RefCell::new(vec![4242, 4242]),
            }
        }
    }

    impl CodeSignature for Fake {
        fn parent_pid(&self) -> u32 {
            let mut pids = self.pids.borrow_mut();
            if pids.len() > 1 {
                pids.remove(0)
            } else {
                pids[0]
            }
        }
        fn satisfies(&self, _pid: u32, requirement: &str) -> Result<(), String> {
            let Some(team) = self.parent_team else {
                return Err("not signed at all".into());
            };
            let wanted_id = format!("identifier \"{}\"", self.parent_id);
            let wanted_team = format!("leaf[subject.OU] = \"{team}\"");
            if requirement.contains(&wanted_id) && requirement.contains(&wanted_team) {
                Ok(())
            } else {
                Err("requirement not satisfied".into())
            }
        }
    }

    #[test]
    fn the_requirement_has_the_shape_of_the_fan_helpers() {
        let text = requirement(TEAM);
        assert!(
            text.starts_with("anchor apple generic and identifier \"com.symaira.cockpit\" and ")
        );
        assert!(text.contains("certificate leaf[subject.OU] = \"ABCDE12345\""));
        assert!(!text.contains('\n') && !text.contains("  "), "{text}");
        // Pinned to the Swift source of the other half of the trust root.
        let swift = include_str!(
            "../../../tuning/Sources/SymCockpitHelperKit/CodeSigningRequirements.swift"
        );
        let constants =
            include_str!("../../../tuning/Sources/SymCockpitHelperKit/FanHelperConstants.swift");
        assert!(constants.contains(&format!("appIdentifier = \"{APP_IDENTIFIER}\"")));
        for needle in [
            "anchor apple generic",
            "certificate leaf[field.1.2.840.113635.100.6.1.13] exists",
            "certificate 1[field.1.2.840.113635.100.6.2.6] exists",
            "certificate leaf[subject.OU] = ",
        ] {
            assert!(swift.contains(needle), "{needle}");
            assert!(text.contains(needle), "{needle}");
        }
        for entitlement in FORBIDDEN_ENTITLEMENTS {
            assert!(
                swift.contains(&format!("\"{entitlement}\"")),
                "{entitlement}"
            );
            assert!(text.contains(&format!("!entitlement[\"{entitlement}\"] exists")));
        }
    }

    #[test]
    fn the_signed_app_of_the_baked_team_is_accepted() {
        assert_eq!(check_parent(&Fake::new(Some(TEAM)), Some(TEAM)), Ok(()));
    }

    #[test]
    fn another_team_or_identifier_is_refused() {
        let other_team = Fake::new(Some("ZZZZZ99999"));
        assert!(matches!(
            check_parent(&other_team, Some(TEAM)),
            Err(ParentError::Unsigned(_))
        ));
        let mut other_id = Fake::new(Some(TEAM));
        other_id.parent_id = "com.example.other";
        assert!(matches!(
            check_parent(&other_id, Some(TEAM)),
            Err(ParentError::Unsigned(_))
        ));
    }

    #[test]
    fn an_unsigned_parent_is_refused() {
        assert!(matches!(
            check_parent(&Fake::new(None), Some(TEAM)),
            Err(ParentError::Unsigned(reason)) if reason == "not signed at all"
        ));
    }

    #[test]
    fn a_build_without_a_team_refuses_to_serve() {
        assert_eq!(
            check_parent(&Fake::new(Some(TEAM)), None),
            Err(ParentError::NoTeam)
        );
    }

    #[test]
    fn a_malformed_team_never_reaches_the_requirement() {
        for bad in ["abcde12345", "ABCDE1234", "ABCDE12345\" or true", ""] {
            assert_eq!(
                check_parent(&Fake::new(Some(TEAM)), Some(bad)),
                Err(ParentError::BadTeam(bad.to_owned())),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn a_parent_that_changes_during_the_check_is_refused() {
        let fake = Fake::new(Some(TEAM));
        *fake.pids.borrow_mut() = vec![4242, 1];
        assert_eq!(
            check_parent(&fake, Some(TEAM)),
            Err(ParentError::ParentChanged)
        );
    }

    // The tests below call the real Security.framework.

    fn sleeper() -> std::process::Child {
        std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap()
    }

    #[test]
    fn the_real_check_accepts_a_matching_requirement_and_rejects_a_wrong_one() {
        let mut child = sleeper();
        let pid = child.id();
        // /bin/sleep is an Apple platform binary: a stable, signed process.
        let ok = SystemSignature.satisfies(pid, "anchor apple and identifier \"com.apple.sleep\"");
        let wrong_id =
            SystemSignature.satisfies(pid, "anchor apple and identifier \"com.symaira.cockpit\"");
        let not_ours = SystemSignature.satisfies(pid, &requirement(TEAM));
        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(ok, Ok(()));
        assert!(wrong_id.is_err(), "{wrong_id:?}");
        assert!(not_ours.is_err(), "{not_ours:?}");
    }

    #[test]
    fn the_real_check_refuses_this_unsigned_test_run() {
        // The parent of a test binary is cargo or a shell: never the signed app.
        let result = check_parent(&SystemSignature, Some(TEAM));
        assert!(
            matches!(result, Err(ParentError::Unsigned(_))),
            "{result:?}"
        );
    }

    #[test]
    fn a_dead_pid_is_an_error_not_a_crash() {
        let mut child = sleeper();
        let pid = child.id();
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(SystemSignature.satisfies(pid, "anchor apple").is_err());
    }
}
