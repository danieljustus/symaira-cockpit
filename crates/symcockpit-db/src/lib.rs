//! `cockpit.sqlite` adapters. Separate from `symcockpit-store` because core
//! depends on store (read side) and these implement core traits.

pub mod smart_history;
