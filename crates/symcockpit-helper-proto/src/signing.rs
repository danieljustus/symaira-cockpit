//! Code-signing requirement strings of the two directions of the helper
//! connection (port of `CodeSigningRequirements.swift`, identical text).
//!
//! Both are anchored on Apple's Developer ID chain and pinned to one team
//! identifier that comes from the running binary's own signature, never from
//! a literal. The helper accepts only the app, the app accepts only the
//! helper. Peers carrying a hardened-runtime escape entitlement are refused.

use crate::{APP_IDENTIFIER, HELPER_IDENTIFIER};

/// Entitlements that defeat the hardened runtime.
pub const FORBIDDEN_ENTITLEMENTS: [&str; 4] = [
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.allow-jit",
];

/// Apple team identifiers are ten upper-case alphanumerics. Anything else is
/// rejected before it can reach a requirement string, which closes
/// requirement-language injection through a forged value.
pub fn is_valid_team_identifier(value: &str) -> bool {
    value.len() == 10
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || b.is_ascii_uppercase())
}

/// What the helper requires of its client.
pub fn app_requirement(team_id: &str) -> Option<String> {
    requirement(APP_IDENTIFIER, team_id)
}

/// What the client requires of the helper.
pub fn helper_requirement(team_id: &str) -> Option<String> {
    requirement(HELPER_IDENTIFIER, team_id)
}

fn requirement(identifier: &str, team_id: &str) -> Option<String> {
    if !is_valid_team_identifier(team_id) {
        return None;
    }
    let denied = FORBIDDEN_ENTITLEMENTS
        .iter()
        .map(|e| format!("!entitlement[\"{e}\"] exists"))
        .collect::<Vec<_>>()
        .join(" and ");
    Some(format!(
        "anchor apple generic and identifier \"{identifier}\" \
         and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
         and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
         and certificate leaf[subject.OU] = \"{team_id}\" and {denied}"
    ))
}

/// Which side of the connection is deciding.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Role {
    /// The helper deciding whether to accept its client.
    HelperAcceptingClient,
    /// The client deciding whether to accept the helper.
    ClientAcceptingHelper,
}

/// Requirements for one side, or the reason to refuse every connection.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Decision {
    /// What the peer must satisfy.
    pub peer: String,
    /// What this process itself must satisfy before it talks to anyone.
    pub own: String,
}

/// Fails closed (port of `FanHelperConnectionPolicy.decide`): no team baked in
/// at build time, a malformed team, an own team that differs from the baked-in
/// one, or no team at all (unsigned/ad-hoc) refuse every connection.
pub fn decide(
    role: Role,
    own_team_id: Option<&str>,
    embedded_team_id: Option<&str>,
) -> Result<Decision, &'static str> {
    let embedded = embedded_team_id.ok_or("this build has no embedded team identifier")?;
    if !is_valid_team_identifier(embedded) {
        return Err("malformed embedded team identifier");
    }
    let own = own_team_id.ok_or("this binary carries no team identifier (unsigned or ad-hoc)")?;
    if !is_valid_team_identifier(own) {
        return Err("malformed team identifier");
    }
    if own != embedded {
        return Err("signing team does not match the team embedded at build time");
    }
    let (peer, own_req) = match role {
        Role::HelperAcceptingClient => (app_requirement(own), helper_requirement(own)),
        Role::ClientAcceptingHelper => (helper_requirement(own), app_requirement(own)),
    };
    match (peer, own_req) {
        (Some(peer), Some(own)) => Ok(Decision { peer, own }),
        _ => Err("could not construct a code-signing requirement"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectors: tuning/Tests/SymCockpitHelperKitTests (CodeSigningRequirements,
    // FanHelperConnectionPolicy); the expected text is Swift's, character for character.
    const TEAM: &str = "ABCDE12345";

    #[test]
    fn team_identifier_is_ten_upper_case_alphanumerics() {
        assert!(is_valid_team_identifier(TEAM));
        for bad in [
            "",
            "abcde12345",
            "ABCDE1234",
            "ABCDE123456",
            "ABCDE12 45",
            "ABCDE12345\"",
            "ABCDE1234é",
        ] {
            assert!(!is_valid_team_identifier(bad), "{bad:?}");
            assert_eq!(app_requirement(bad), None);
        }
    }

    #[test]
    fn requirement_text_matches_swift() {
        let want = "anchor apple generic and identifier \"com.symaira.cockpit\" \
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
and certificate leaf[subject.OU] = \"ABCDE12345\" \
and !entitlement[\"com.apple.security.cs.allow-dyld-environment-variables\"] exists \
and !entitlement[\"com.apple.security.cs.disable-library-validation\"] exists \
and !entitlement[\"com.apple.security.cs.allow-unsigned-executable-memory\"] exists \
and !entitlement[\"com.apple.security.cs.allow-jit\"] exists";
        assert_eq!(app_requirement(TEAM).unwrap(), want);
        assert_eq!(
            helper_requirement(TEAM).unwrap(),
            want.replace("com.symaira.cockpit", "com.symaira.symtune-helper")
        );
    }

    #[test]
    fn both_sides_pin_each_other_and_fail_closed() {
        let helper = decide(Role::HelperAcceptingClient, Some(TEAM), Some(TEAM)).unwrap();
        assert_eq!(Some(helper.peer), app_requirement(TEAM));
        assert_eq!(Some(helper.own), helper_requirement(TEAM));
        let client = decide(Role::ClientAcceptingHelper, Some(TEAM), Some(TEAM)).unwrap();
        assert_eq!(Some(client.peer), helper_requirement(TEAM));

        for (own, embedded, why) in [
            (Some(TEAM), None, "no embedded"),
            (Some(TEAM), Some("bad"), "malformed embedded"),
            (None, Some(TEAM), "no team"),
            (Some("bad"), Some(TEAM), "malformed team"),
            (Some("ZZZZZ99999"), Some(TEAM), "does not match"),
        ] {
            let err = decide(Role::HelperAcceptingClient, own, embedded).unwrap_err();
            assert!(err.contains(why), "{err}");
        }
    }
}
