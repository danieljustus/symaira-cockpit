//! Minimal Objective-C object building for the aggregate-device dictionaries
//! (`NSMutableDictionary` / `NSMutableArray`, toll-free bridged to their CF
//! counterparts). Pattern from spike S4.

use objc2::msg_send;
use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject};
use objc2_foundation::NSString;

pub(super) fn new_obj(class: &str) -> Result<Retained<AnyObject>, String> {
    let name = std::ffi::CString::new(class).map_err(|e| e.to_string())?;
    let cls = AnyClass::get(&name).ok_or_else(|| format!("{class} is missing"))?;
    // SAFETY: `+new` on a Foundation collection class takes no arguments and returns a +1 object.
    let obj: Option<Retained<AnyObject>> = unsafe { msg_send![cls, new] };
    obj.ok_or_else(|| format!("{class} new returned nil"))
}

pub(super) fn dict_set<V: objc2::Message>(dict: &AnyObject, key: &NSString, value: &Retained<V>) {
    // SAFETY: `dict` is an NSMutableDictionary, `key` an NSString (copyable key), `value` any object.
    unsafe {
        let _: () = msg_send![dict, setObject: &**value, forKey: key];
    }
}

pub(super) fn array_of(items: &[&AnyObject]) -> Result<Retained<AnyObject>, String> {
    let array = new_obj("NSMutableArray")?;
    for item in items {
        // SAFETY: `array` is an NSMutableArray and `item` a live object.
        unsafe {
            let _: () = msg_send![&*array, addObject: *item];
        }
    }
    Ok(array)
}
