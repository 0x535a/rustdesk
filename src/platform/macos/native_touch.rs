use base::native_touch::{Contact, Frame};
use core_graphics::display::{
    kCGDisplayShowDuplicateLowResolutionModes, CGDisplay, CGDisplayCopyAllDisplayModes,
    CGDisplayModeGetHeight, CGDisplayModeGetIOFlags, CGDisplayModeGetWidth,
};
use hbb_common::{
    anyhow::{anyhow, bail},
    log,
    tokio::{
        io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
        process::{Child, ChildStderr, ChildStdin, Command},
        time::{timeout, Duration},
    },
    ResultType,
};
use std::{
    path::PathBuf,
    process::Stdio,
    sync::atomic::{AtomicBool, Ordering},
};

static IN_USE: AtomicBool = AtomicBool::new(false);

fn is_virtual_touch_display(display: u32) -> bool {
    use cocoa::base::{id, nil, BOOL, YES};
    use objc::{msg_send, rc::autoreleasepool, runtime::Class, sel, sel_impl};

    let Some(class) = Class::get("CADisplay") else {
        return false;
    };
    autoreleasepool(|| unsafe {
        let supported: BOOL = msg_send![class, respondsToSelector: sel!(displays)];
        if supported != YES {
            return false;
        }
        let displays: id = msg_send![class, displays];
        if displays == nil {
            return false;
        }
        let count: usize = msg_send![displays, count];
        for index in 0..count {
            let entry: id = msg_send![displays, objectAtIndex: index];
            let has_id: BOOL = msg_send![entry, respondsToSelector: sel!(displayId)];
            let has_type: BOOL = msg_send![entry, respondsToSelector: sel!(displayType)];
            if has_id != YES || has_type != YES {
                continue;
            }
            let entry_id: u32 = msg_send![entry, displayId];
            if entry_id == display {
                let display_type: usize = msg_send![entry, displayType];
                return display_type == 3;
            }
        }
        false
    })
}

fn native_touch_coordinates(x: f64, y: f64, rotation: i32, scale: (f64, f64)) -> (f64, f64) {
    let (x, y) = (x * scale.0, y * scale.1);
    match rotation.rem_euclid(360) {
        90 => (y, 1.0 - x),
        180 => (1.0 - x, 1.0 - y),
        270 => (1.0 - y, x),
        _ => (x, y),
    }
}

fn native_touch_scale(logical: (u64, u64), reference: (u64, u64)) -> (f64, f64) {
    (
        logical.0 as f64 / reference.0 as f64,
        logical.1 as f64 / reference.1 as f64,
    )
}

fn native_touch_reference_size(display: u32) -> ResultType<(u64, u64)> {
    use core_foundation::{
        array::CFArray, base::TCFType, boolean::CFBoolean, dictionary::CFDictionary,
        string::CFString,
    };

    const DEFAULT_MODE_FLAG: u32 = 0x00000004;
    let options = CFDictionary::from_CFType_pairs(&[(
        unsafe { CFString::wrap_under_get_rule(kCGDisplayShowDuplicateLowResolutionModes) },
        CFBoolean::true_value(),
    )]);
    let array = unsafe { CGDisplayCopyAllDisplayModes(display, options.as_concrete_TypeRef()) };
    if array.is_null() {
        bail!("Native touch display modes are unavailable");
    }
    let modes: CFArray = unsafe { CFArray::wrap_under_create_rule(array) };
    for mode in modes.iter() {
        // The array owns these mode references; only copy their dimensions.
        let flags = unsafe { CGDisplayModeGetIOFlags(*mode as _) };
        if flags & DEFAULT_MODE_FLAG != 0 {
            let size = unsafe {
                (
                    CGDisplayModeGetWidth(*mode as _) as u64,
                    CGDisplayModeGetHeight(*mode as _) as u64,
                )
            };
            if size.0 == 0 || size.1 == 0 {
                bail!("Native touch default display mode has an empty size");
            }
            return Ok(size);
        }
    }
    bail!("Native touch default display mode is unavailable")
}

struct Permit;
impl Drop for Permit {
    fn drop(&mut self) {
        IN_USE.store(false, Ordering::SeqCst);
    }
}

pub(crate) fn helper_path() -> Option<PathBuf> {
    let path = std::env::current_exe()
        .ok()?
        .parent()?
        .join("TouchInjector");
    path.is_file().then_some(path)
}

#[derive(Default)]
pub(crate) struct Session {
    child: Option<Child>,
    input: Option<ChildStdin>,
    errors: Option<ChildStderr>,
    display: Option<u32>,
    permit: Option<Permit>,
}

impl Session {
    pub(crate) fn active(&self) -> bool {
        self.child.is_some()
    }

    pub(crate) async fn start(&mut self, display: u32) -> ResultType<()> {
        self.stop().await;
        let helper =
            helper_path().ok_or_else(|| anyhow!("Native touch helper is not installed"))?;
        if IN_USE
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            bail!("Native touch is in use by another session");
        }
        self.permit = Some(Permit);
        let result = self.spawn(helper, display).await;
        if result.is_err() {
            self.stop().await;
        }
        result
    }

    async fn spawn(&mut self, helper: PathBuf, display: u32) -> ResultType<()> {
        let mut child = Command::new(helper)
            .args(["--session", "--display", &display.to_string()])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        self.input = child.stdin.take();
        let output = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("Native touch helper has no status pipe"))?;
        self.errors = child.stderr.take();
        self.child = Some(child);
        let mut line = String::new();
        let mut reader = BufReader::new(output).take(4096);
        // Initialization must prove CoreHID creation succeeded before the client enables touch.
        let ready = timeout(Duration::from_secs(4), reader.read_line(&mut line)).await;
        let status = serde_json::from_str::<serde_json::Value>(&line).ok();
        if !matches!(ready, Ok(Ok(n)) if n > 0)
            || status
                .as_ref()
                .and_then(|v| v.get("ready"))
                .and_then(|v| v.as_bool())
                != Some(true)
            || status
                .as_ref()
                .and_then(|v| v.get("maximum_contacts"))
                .and_then(|v| v.as_u64())
                != Some(10)
        {
            let mut detail = String::new();
            if let Some(errors) = self.errors.take() {
                match timeout(
                    Duration::from_millis(200),
                    errors.take(4096).read_to_string(&mut detail),
                )
                .await
                {
                    Ok(Ok(_)) => {}
                    result => log::trace!("Native touch helper diagnostics: {result:?}"),
                }
            }
            bail!(
                "Native touch helper failed to initialize: {}",
                detail.trim()
            );
        }
        self.display = Some(display);
        Ok(())
    }

    pub(crate) async fn send(&mut self, frame: &Frame, display: u32) -> ResultType<()> {
        if !frame.validate() || self.display != Some(display) {
            bail!("Invalid native touch frame or display");
        }
        let child = self
            .child
            .as_mut()
            .ok_or_else(|| anyhow!("Native touch is not enabled"))?;
        if let Some(status) = child.try_wait()? {
            bail!("Native touch helper exited: {status}");
        }
        let mut data = serde_json::to_vec(&serde_json::json!({"contacts": frame.contacts}))?;
        let current = CGDisplay::new(display);
        let rotation = current.rotation().round() as i32;
        let mut scale = (1.0, 1.0);
        if is_virtual_touch_display(display) {
            let mode = current
                .display_mode()
                .ok_or_else(|| anyhow!("Native touch display mode is unavailable"))?;
            // Virtual-display HID coordinates refer to the default mode, not the current backing buffer.
            scale = native_touch_scale(
                (mode.width(), mode.height()),
                native_touch_reference_size(display)?,
            );
        }
        if rotation != 0 || scale != (1.0, 1.0) {
            let contacts: Vec<_> = frame
                .contacts
                .iter()
                .map(|point| {
                    let (x, y) = native_touch_coordinates(point.x, point.y, rotation, scale);
                    Contact { id: point.id, x, y }
                })
                .collect();
            data = serde_json::to_vec(&serde_json::json!({"contacts": contacts}))?;
        }
        data.push(b'\n');
        let input = self
            .input
            .as_mut()
            .ok_or_else(|| anyhow!("Native touch input pipe closed"))?;
        timeout(Duration::from_secs(1), input.write_all(&data)).await??;
        Ok(())
    }

    pub(crate) async fn stop(&mut self) {
        // Closing the private pipe sends EOF, releasing contacts before the helper exits.
        self.input.take();
        if let Some(mut child) = self.child.take() {
            match timeout(Duration::from_secs(1), child.wait()).await {
                Ok(Ok(_)) => {}
                result => {
                    log::trace!("Native touch helper shutdown: {result:?}");
                    if let Err(error) = child.kill().await {
                        log::trace!("Native touch helper kill: {error}");
                    }
                }
            }
        }
        self.display = None;
        self.errors.take();
        self.permit.take();
    }
}

#[cfg(test)]
mod tests {
    use super::{native_touch_coordinates, native_touch_scale};

    #[test]
    fn screen_coordinates_compensate_clockwise_display_rotation() {
        assert_eq!(
            native_touch_coordinates(0.25, 0.625, 90, (1.0, 1.0)),
            (0.625, 0.75)
        );
        assert_eq!(
            native_touch_coordinates(0.25, 0.625, 180, (1.0, 1.0)),
            (0.75, 0.375)
        );
        assert_eq!(
            native_touch_coordinates(0.25, 0.625, 270, (1.0, 1.0)),
            (0.375, 0.25)
        );
    }

    #[test]
    fn virtual_mode_switch_uses_default_logical_size_in_both_directions() {
        let reference = (2388, 1668);
        for (logical, expected) in [
            ((2388, 1668), (1.0, 1.0)),
            ((1194, 834), (0.5, 0.5)),
            ((2388, 1668), (1.0, 1.0)),
        ] {
            assert_eq!(native_touch_scale(logical, reference), expected);
        }
    }
}
