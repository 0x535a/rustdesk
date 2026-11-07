use base::native_touch::Frame;
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
