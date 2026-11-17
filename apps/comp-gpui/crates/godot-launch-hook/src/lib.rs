//! Loaded into the Godot child with DYLD_INSERT_LIBRARIES so it never shows a Dock icon or
//! takes focus from the host.
//!
//! Godot's macOS OS constructor calls `[NSApp setActivationPolicy:Regular]` before any
//! GDExtension loads, and showing its main window runs `-[GodotApplication activateApplication]`,
//! whose unbundled-launch hack transforms the process back into a foreground app. This
//! library's initializer runs before Godot's `main`: NSApplication turns every request for the
//! Regular policy into Accessory, and activateApplication does nothing.

#[cfg(target_os = "macos")]
mod mac {
    use std::sync::OnceLock;

    use objc2::runtime::{AnyClass, AnyObject, Bool, Imp, Sel};
    use objc2::sel;

    #[link(name = "AppKit", kind = "framework")]
    unsafe extern "C" {}

    const REGULAR: isize = 0;
    const ACCESSORY: isize = 1;

    type SetPolicy = unsafe extern "C-unwind" fn(*mut AnyObject, Sel, isize) -> Bool;
    type Action = unsafe extern "C-unwind" fn(*mut AnyObject, Sel);

    static ORIGINAL_SET_POLICY: OnceLock<SetPolicy> = OnceLock::new();

    unsafe extern "C-unwind" fn set_activation_policy(
        this: *mut AnyObject,
        cmd: Sel,
        policy: isize,
    ) -> Bool {
        let policy = if policy == REGULAR { ACCESSORY } else { policy };
        match ORIGINAL_SET_POLICY.get() {
            Some(original) => unsafe { original(this, cmd, policy) },
            None => Bool::NO,
        }
    }

    unsafe extern "C-unwind" fn do_nothing(_: *mut AnyObject, _: Sel) {}

    fn replace(class: &AnyClass, sel: Sel, imp: Imp) -> Option<Imp> {
        let method = class.instance_method(sel)?;
        Some(unsafe { method.set_implementation(imp) })
    }

    extern "C" fn install() {
        if let Some(app) = AnyClass::get(c"NSApplication") {
            let imp = unsafe {
                std::mem::transmute::<SetPolicy, Imp>(set_activation_policy as SetPolicy)
            };
            if let Some(original) = replace(app, sel!(setActivationPolicy:), imp) {
                let _ = ORIGINAL_SET_POLICY
                    .set(unsafe { std::mem::transmute::<Imp, SetPolicy>(original) });
            }
        }
        if let Some(godot_app) = AnyClass::get(c"GodotApplication") {
            let imp = unsafe { std::mem::transmute::<Action, Imp>(do_nothing as Action) };
            replace(godot_app, sel!(activateApplication), imp);
        }
    }

    #[used]
    #[unsafe(link_section = "__DATA,__mod_init_func")]
    static INSTALL: extern "C" fn() = install;
}
