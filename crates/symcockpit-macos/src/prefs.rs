//! The user's preferences (`CFPreferences`), read only.

use core_foundation::base::{CFType, TCFType};
use core_foundation::string::CFString;
use core_foundation_sys::array::{CFArrayGetCount, CFArrayGetTypeID, CFArrayGetValueAtIndex};
use core_foundation_sys::base::{CFGetTypeID, CFTypeRef};
use core_foundation_sys::preferences::CFPreferencesCopyAppValue;
use core_foundation_sys::string::CFStringGetTypeID;

/// `UserDefaults(suiteName: domain).stringArray(forKey: key)`: `None` when the key is
/// absent or is not an array of strings.
pub fn string_array(domain: &str, key: &str) -> Option<Vec<String>> {
    let (domain, key) = (CFString::new(domain), CFString::new(key));
    // SAFETY: both arguments are live CFStrings; the copy rule gives us one reference.
    let value: CFTypeRef = unsafe {
        CFPreferencesCopyAppValue(key.as_concrete_TypeRef(), domain.as_concrete_TypeRef())
    };
    if value.is_null() {
        return None;
    }
    // SAFETY: `value` is a non-null CFType we own; it is released below.
    let owned = unsafe { CFType::wrap_under_create_rule(value) };
    let raw = owned.as_CFTypeRef();
    // SAFETY: `raw` is a valid CFType, the type ids are plain queries, and every element
    // is checked to be a CFString before it is wrapped.
    unsafe {
        if CFGetTypeID(raw) != CFArrayGetTypeID() {
            return None;
        }
        let array = raw.cast();
        (0..CFArrayGetCount(array))
            .map(|i| {
                let item = CFArrayGetValueAtIndex(array, i);
                (!item.is_null() && CFGetTypeID(item) == CFStringGetTypeID())
                    .then(|| CFString::wrap_under_get_rule(item.cast()).to_string())
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_absent_key_is_none() {
        assert_eq!(
            string_array("com.symaira.test-domain-none", "nothing.here"),
            None
        );
    }
}
