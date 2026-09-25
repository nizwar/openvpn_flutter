//! OpenVPN process management on Windows

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use std::fs::OpenOptions;
use std::io::Write;
#[cfg(target_os = "windows")]
use tokio::process::{Child as TokioChild, Command as TokioCommand};
use tokio::io::{AsyncBufReadExt, BufReader};
use crate::error::OpenVpnError;
use crate::service_ipc;

// ── Helpers ─────────────────────────────────────────────────────────────────

const ENABLE_DEBUG_LOGS: bool = false;

fn debug_log_to_file(msg: &str) {
    if !ENABLE_DEBUG_LOGS {
        return;
    }
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(std::env::temp_dir().join("openvpn_rust_debug.log"))
    {
        let _ = writeln!(file, "{}", msg);
        let _ = file.flush();
    }
    eprintln!("{}", msg);
}

fn diag_log_to_file(msg: &str) {
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(std::env::temp_dir().join("openvpn_rust_diag.log"))
    {
        let _ = writeln!(file, "{}", msg);
        let _ = file.flush();
    }
}

fn sanitize_for_log(line: &str) -> String {
    let collapsed = line.replace('\r', " ").replace('\n', " ");
    let trimmed = collapsed.trim();
    const MAX_LEN: usize = 240;
    if trimmed.len() > MAX_LEN {
        format!("{}...", &trimmed[..MAX_LEN])
    } else {
        trimmed.to_string()
    }
}

fn classify_reason(line: &str) -> &'static str {
    let line_lower = line.to_lowercase();
    if line_lower.contains("auth_failed") || line_lower.contains("authentication failed") {
        "AUTH_FAILED"
    } else if line_lower.contains("ovpn-dco")
        && (line_lower.contains("failed")
            || line_lower.contains("error")
            || line_lower.contains("not installed"))
    {
        "OVPN_DCO_FAILED"
    } else if line_lower.contains("tap-windows")
        && (line_lower.contains("failed")
            || line_lower.contains("not found")
            || line_lower.contains("cannot allocate"))
    {
        "TAP_ADAPTER_MISSING"
    } else if line_lower.contains("tls handshake failed") || line_lower.contains("tls error") {
        "TLS_FAILED"
    } else if line_lower.contains("cannot resolve host address")
        || line_lower.contains("resolve error")
    {
        "DNS_RESOLVE_FAILED"
    } else if line_lower.contains("connection timed out") {
        "CONNECT_TIMEOUT"
    } else if line_lower.contains("connection refused") {
        "CONNECTION_REFUSED"
    } else if line_lower.contains("certificate verify failed")
        || line_lower.contains("verify error")
    {
        "CERT_VERIFY_FAILED"
    } else if line_lower.contains("network is unreachable") {
        "NETWORK_UNREACHABLE"
    } else if line_lower.contains("fatal") {
        "FATAL"
    } else if line_lower.contains("service ipc") || line_lower.contains("pipe") {
        "SERVICE_IPC_FAILED"
    } else {
        "UNKNOWN"
    }
}

fn log_stage_transition(stream: &str, from: &str, to: &str, line: &str, start: Instant) {
    let elapsed_ms = start.elapsed().as_millis();
    let reason_code = classify_reason(line);
    let trigger_line = sanitize_for_log(line);
    diag_log_to_file(&format!(
        "[RUST_STAGE] stream={} from={} to={} elapsedMs={} reasonCode={} trigger=\"{}\"",
        stream, from, to, elapsed_ms, reason_code, trigger_line
    ));
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum DriverStrategy {
    OvpnDco,
    TapWindows6,
}

#[derive(Debug)]
enum ConnectOutcome {
    Connected,
    DriverFailed,
    FatalError,
    StillRunning,
}

fn preprocess_config_for_driver(config: &str, strategy: DriverStrategy) -> String {
    let mut out: Vec<String> = config
        .lines()
        .filter(|line| {
            let t = line.trim().to_lowercase();
            !t.starts_with("disable-dco") && !t.starts_with("windows-driver")
        })
        .map(|s| s.to_string())
        .collect();

    if strategy == DriverStrategy::TapWindows6 {
        out.push("disable-dco".to_string());
    }
    out.join("\n")
}

fn build_service_cli_options(
    config_file: &PathBuf,
    auth_file: &Option<PathBuf>,
    status_file: &PathBuf,
    log_file: &PathBuf,
    strategy: DriverStrategy,
) -> String {
    let mut opts = format!("--config \"{}\"", config_file.display());
    if let Some(ref ap) = auth_file {
        opts.push_str(&format!(" --auth-user-pass \"{}\"", ap.display()));
    }
    opts.push_str(" --verb 4");
    opts.push_str(&format!(" --status \"{}\" 2", status_file.display()));
    opts.push_str(&format!(" --log \"{}\"", log_file.display()));
    match strategy {
        DriverStrategy::OvpnDco => opts.push_str(" --windows-driver ovpn-dco"),
        DriverStrategy::TapWindows6 => opts.push_str(" --windows-driver tap-windows6"),
    }
    opts
}

fn driver_strategy_label(strategy: DriverStrategy) -> &'static str {
    match strategy {
        DriverStrategy::OvpnDco => "ovpn-dco_via_service",
        DriverStrategy::TapWindows6 => "tap-windows6_fallback",
    }
}

const PREFERRED_DRIVER_FILE: &str = "preferred_driver.txt";
const IMAGE_FILE_MACHINE_ARM64: u16 = 0xAA64;

/// Kernel arch folder under `LavControl/OpenVPN` (`x64` or `arm64`), matching
/// the Dart [WindowsBinaryManager] layout.
#[cfg(target_os = "windows")]
fn windows_kernel_arch_folder() -> &'static str {
    unsafe {
        extern "system" {
            fn GetCurrentProcess() -> *mut std::ffi::c_void;
            fn IsWow64Process2(
                hProcess: *mut std::ffi::c_void,
                pProcessMachine: *mut u16,
                pNativeMachine: *mut u16,
            ) -> i32;
        }
        let mut process_machine: u16 = 0;
        let mut native_machine: u16 = 0;
        let ok = IsWow64Process2(
            GetCurrentProcess(),
            &mut process_machine,
            &mut native_machine,
        );
        if ok != 0 && native_machine == IMAGE_FILE_MACHINE_ARM64 {
            return "arm64";
        }
    }
    "x64"
}

#[cfg(not(target_os = "windows"))]
fn windows_kernel_arch_folder() -> &'static str {
    "x64"
}

/// Reads `preferred_driver.txt` next to the config directory (machine runtime
/// root). Returns `ovpn-dco`, `tap-windows6`, or `None` when absent/unknown.
fn read_preferred_driver(config_dir: &PathBuf) -> Option<String> {
    let marker = config_dir
        .parent()
        .map(|p| p.join(PREFERRED_DRIVER_FILE))?;
    let content = std::fs::read_to_string(&marker).ok()?;
    let value = content.trim().to_ascii_lowercase();
    match value.as_str() {
        "ovpn-dco" | "tap-windows6" => {
            diag_log_to_file(&format!(
                "[RUST_CONNECT] preferred_driver={} path=\"{}\"",
                value,
                marker.display()
            ));
            Some(value)
        }
        other if !other.is_empty() => {
            diag_log_to_file(&format!(
                "[RUST_CONNECT] preferred_driver unknown=\"{}\" path=\"{}\"",
                other,
                marker.display()
            ));
            None
        }
        _ => None,
    }
}

/// Service-mode driver attempts: marker forces a single strategy; absent marker
/// keeps the historical DCO-then-TAP fallback.
fn service_driver_strategies(preferred: Option<&str>) -> Vec<DriverStrategy> {
    match preferred {
        Some("ovpn-dco") => vec![DriverStrategy::OvpnDco],
        Some("tap-windows6") => vec![DriverStrategy::TapWindows6],
        _ => vec![DriverStrategy::OvpnDco, DriverStrategy::TapWindows6],
    }
}

fn is_dco_failure_line(line: &str) -> bool {
    let l = line.to_lowercase();
    if l.contains("cannot allocate tun/tap") {
        return true;
    }
    if l.contains("tap-windows6") && l.contains("currently in use") {
        return true;
    }
    (l.contains("ovpn-dco") || l.contains("dco version: n/a") || l.contains("data channel offload"))
        && (l.contains("failed")
            || l.contains("error")
            || l.contains("not found")
            || l.contains("not installed")
            || l.contains("cannot"))
}

async fn wait_for_connect_outcome(
    log_path: &PathBuf,
    pid: u32,
    timeout: Duration,
) -> ConnectOutcome {
    let started = Instant::now();
    let mut tailer = service_ipc::LogFileTailer::new(log_path.clone());

    while started.elapsed() < timeout {
        tokio::time::sleep(Duration::from_millis(300)).await;

        if !service_ipc::is_pid_alive(pid) {
            return ConnectOutcome::FatalError;
        }

        for line in tailer.read_new_lines() {
            let lower = line.to_lowercase();
            if lower.contains("initialization sequence completed") {
                return ConnectOutcome::Connected;
            }
            if is_dco_failure_line(&line) {
                return ConnectOutcome::DriverFailed;
            }
            if let Some(stage) = parse_stage_from_output(&line) {
                if stage == "error" {
                    return ConnectOutcome::FatalError;
                }
            }
        }
    }
    ConnectOutcome::StillRunning
}

async fn kill_all_openvpn_processes() {
    debug_log_to_file("[DEBUG] Attempting to kill all OpenVPN processes...");
    let mut kill_cmd = TokioCommand::new("taskkill");
    kill_cmd.args(&["/F", "/IM", "openvpn.exe", "/T"]);
    #[cfg(target_os = "windows")]
    {
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        kill_cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let output = kill_cmd.output().await;
    match output {
        Ok(output) => {
            if output.status.success() {
                debug_log_to_file("[DEBUG] Successfully killed all OpenVPN processes");
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                if stderr.contains("not found") || stderr.contains("not running") {
                    debug_log_to_file("[DEBUG] No OpenVPN processes found to kill");
                } else {
                    debug_log_to_file(&format!("[DEBUG] Warning: taskkill failed: {}", stderr));
                }
            }
        }
        Err(e) => {
            debug_log_to_file(&format!(
                "[DEBUG] Warning: Failed to execute taskkill: {}",
                e
            ));
        }
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
}

async fn restart_interactive_service() -> bool {
    diag_log_to_file("[RUST_SERVICE] restarting OpenVPNServiceInteractive...");

    let stop = {
        let mut cmd = TokioCommand::new("net");
        cmd.args(["stop", "OpenVPNServiceInteractive"]);
        #[cfg(target_os = "windows")]
        {
            const CREATE_NO_WINDOW: u32 = 0x08000000;
            cmd.creation_flags(CREATE_NO_WINDOW);
        }
        cmd.output().await
    };
    if let Ok(ref out) = stop {
        let msg = String::from_utf8_lossy(&out.stdout);
        diag_log_to_file(&format!("[RUST_SERVICE] stop: {}", msg.trim()));
    }

    tokio::time::sleep(Duration::from_millis(300)).await;

    let start = {
        let mut cmd = TokioCommand::new("net");
        cmd.args(["start", "OpenVPNServiceInteractive"]);
        #[cfg(target_os = "windows")]
        {
            const CREATE_NO_WINDOW: u32 = 0x08000000;
            cmd.creation_flags(CREATE_NO_WINDOW);
        }
        cmd.output().await
    };
    let ok = match start {
        Ok(ref out) => {
            let msg = String::from_utf8_lossy(&out.stdout);
            diag_log_to_file(&format!("[RUST_SERVICE] start: {}", msg.trim()));
            out.status.success()
        }
        Err(ref e) => {
            diag_log_to_file(&format!("[RUST_SERVICE] start failed: {}", e));
            false
        }
    };

    tokio::time::sleep(Duration::from_millis(200)).await;
    ok
}

async fn kill_process_by_pid(pid: u32) {
    debug_log_to_file(&format!("[DEBUG] Killing PID {}...", pid));
    let mut cmd = TokioCommand::new("taskkill");
    cmd.args(["/F", "/PID", &pid.to_string()]);
    #[cfg(target_os = "windows")]
    {
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    match cmd.output().await {
        Ok(out) => {
            let msg = String::from_utf8_lossy(&out.stdout);
            debug_log_to_file(&format!("[DEBUG] taskkill PID {}: {}", pid, msg.trim()));
        }
        Err(e) => {
            debug_log_to_file(&format!("[DEBUG] taskkill PID {} error: {}", pid, e));
        }
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
}

// ── Types ───────────────────────────────────────────────────────────────────

/// VPN connection statistics
#[derive(Clone, Default)]
pub struct VpnStats {
    pub byte_in: u64,
    pub byte_out: u64,
    pub packets_in: u64,
    pub packets_out: u64,
    pub connected_on: Option<std::time::SystemTime>,
    /// Active Windows driver: "ovpn-dco" or "tap-windows6".
    pub windows_driver: Option<String>,
    /// How openvpn.exe was launched: "service" or "direct".
    pub windows_connect_mode: Option<String>,
}

/// Tracks how the current openvpn.exe was launched.
enum ManagedProcess {
    /// Launched directly via `tokio::process::Command` (stdout/stderr piped).
    Direct(TokioChild),
    /// Launched via the Interactive Service IPC. The service terminates
    /// `openvpn.exe` when `pipe` is closed, so dropping it is the disconnect.
    Service {
        pid: u32,
        pipe: service_ipc::ServicePipe,
    },
}

/// Terminates a service-launched `openvpn.exe`: closing the pipe asks the
/// Interactive Service to stop it; `taskkill` is only a best-effort fallback
/// (it needs privileges the app usually lacks).
async fn stop_service_process(pid: u32, pipe: service_ipc::ServicePipe) {
    drop(pipe);
    tokio::time::sleep(Duration::from_millis(500)).await;
    if service_ipc::is_pid_alive(pid) {
        kill_process_by_pid(pid).await;
    }
}

// ── Manager ─────────────────────────────────────────────────────────────────

pub struct OpenVpnManager {
    binary_path: PathBuf,
    process: Arc<Mutex<Option<ManagedProcess>>>,
    current_stage: Arc<Mutex<String>>,
    config_file: Arc<Mutex<Option<PathBuf>>>,
    auth_file: Arc<Mutex<Option<PathBuf>>>,
    status_file: Arc<Mutex<Option<PathBuf>>>,
    log_file: Arc<Mutex<Option<PathBuf>>>,
    stats: Arc<Mutex<VpnStats>>,
}

impl OpenVpnManager {
    pub fn new(binary_path: String) -> Result<Self, OpenVpnError> {
        debug_log_to_file(&format!(
            "[DEBUG] OpenVpnManager::new() binary_path: {}",
            binary_path
        ));
        let path = PathBuf::from(&binary_path);
        if !path.exists() {
            return Err(OpenVpnError::BinaryNotFound(format!(
                "OpenVPN binary not found at: {}",
                path.display()
            )));
        }
        debug_log_to_file("[DEBUG] OpenVpnManager created successfully");
        Ok(OpenVpnManager {
            binary_path: path,
            process: Arc::new(Mutex::new(None)),
            current_stage: Arc::new(Mutex::new("disconnected".to_string())),
            config_file: Arc::new(Mutex::new(None)),
            auth_file: Arc::new(Mutex::new(None)),
            status_file: Arc::new(Mutex::new(None)),
            log_file: Arc::new(Mutex::new(None)),
            stats: Arc::new(Mutex::new(VpnStats::default())),
        })
    }

    /// Runtime directories for configs/logs shared with the Interactive Service.
    /// Must live under ProgramData so LocalSystem can access them.
    /// Layout mirrors Dart: `LavControl/OpenVPN/<arch>/{config,log,status}`.
    fn runtime_dirs(&self) -> (PathBuf, PathBuf, PathBuf) {
        #[cfg(target_os = "windows")]
        {
            let arch = windows_kernel_arch_folder();
            let base = std::env::var("ProgramData")
                .map(|p| PathBuf::from(p).join("LavControl").join("OpenVPN").join(arch))
                .unwrap_or_else(|_| {
                    PathBuf::from(format!(r"C:\ProgramData\LavControl\OpenVPN\{}", arch))
                });
            return (
                base.join("config"),
                base.join("log"),
                base.join("status"),
            );
        }
        #[cfg(not(target_os = "windows"))]
        {
            let base = self
                .binary_path
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| PathBuf::from("."));
            (
                base.join("config"),
                base.join("log"),
                base.join("status"),
            )
        }
    }

    fn ensure_runtime_dirs(
        config_dir: &PathBuf,
        log_dir: &PathBuf,
        status_dir: &PathBuf,
    ) -> Result<(), OpenVpnError> {
        for dir in [config_dir, log_dir, status_dir] {
            std::fs::create_dir_all(dir).map_err(OpenVpnError::IoError)?;
        }
        Ok(())
    }

    // ── connect ─────────────────────────────────────────────────────────

    pub async fn connect(
        &self,
        config: &str,
        username: Option<String>,
        password: Option<String>,
    ) -> Result<(), OpenVpnError> {
        let connect_started_at = Instant::now();
        debug_log_to_file("[DEBUG] OpenVpnManager::connect() called");
        diag_log_to_file(&format!(
            "[RUST_CONNECT] phase=start configBytes={} hasUsername={} hasPassword={}",
            config.len(),
            username.is_some(),
            password.is_some()
        ));

        // ── 1. Clean up any previous connection ─────────────────────────
        kill_all_openvpn_processes().await;
        {
            let mut process = self.process.lock().unwrap();
            if let Some(managed) = process.take() {
                match managed {
                    ManagedProcess::Direct(mut child) => {
                        let _ = child.kill().await;
                        let _ = child.wait().await;
                    }
                    ManagedProcess::Service { pid, pipe } => {
                        stop_service_process(pid, pipe).await;
                    }
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(1000)).await;

        // ── 2. Write runtime files under the OpenVPN runtime directory ──
        // The Interactive Service rejects configs outside `config_dir`.
        let (config_dir, log_dir, status_dir) = self.runtime_dirs();
        Self::ensure_runtime_dirs(&config_dir, &log_dir, &status_dir)?;

        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();

        let config_file = config_dir.join(format!("openvpn_config_{}.ovpn", ts));
        // Config body is written per driver attempt (DCO strips disable-dco).

        let auth_file = if username.is_some() && password.is_some() {
            let content = format!(
                "{}\n{}",
                username.as_ref().unwrap(),
                password.as_ref().unwrap()
            );
            let path = config_dir.join(format!("openvpn_auth_{}.txt", ts));
            std::fs::write(&path, content).map_err(OpenVpnError::IoError)?;
            Some(path)
        } else {
            None
        };

        let status_file_path = status_dir.join(format!("openvpn_status_{}.txt", ts));

        // Store common temp paths
        {
            *self.config_file.lock().unwrap() = Some(config_file.clone());
        }
        if let Some(ref ap) = auth_file {
            *self.auth_file.lock().unwrap() = Some(ap.clone());
        }
        {
            *self.status_file.lock().unwrap() = Some(status_file_path.clone());
        }
        {
            let mut stats = self.stats.lock().unwrap();
            stats.connected_on = Some(std::time::SystemTime::now());
        }

        // ── 3. Try IPC Interactive Service path ─────────────────────────
        // Only restart the service when the pipe is unavailable (avoids
        // pointless net stop/start attempts from a non-elevated process).
        let service_available_before = service_ipc::is_service_available();
        let service_restarted = if !service_available_before {
            restart_interactive_service().await
        } else {
            false
        };
        let service_available = service_ipc::is_service_available();
        diag_log_to_file(&format!(
            "[RUST_CONNECT] phase=service_check serviceAvailableBefore={} serviceRestarted={} serviceAvailable={}",
            service_available_before, service_restarted, service_available
        ));

        let mut used_service = false;
        let mut active_driver = DriverStrategy::OvpnDco;
        let preferred_driver = read_preferred_driver(&config_dir);
        let preferred_ref = preferred_driver.as_deref();

        if service_available {
            let log_file_path = log_dir.join(format!("openvpn_log_{}.txt", ts));
            {
                *self.log_file.lock().unwrap() = Some(log_file_path.clone());
            }

            let working_dir = config_dir.to_string_lossy().to_string();
            let strategies = service_driver_strategies(preferred_ref);
            let mut connected = false;
            let allow_dco_to_tap_fallback = preferred_ref.is_none();

            for (idx, strategy) in strategies.iter().enumerate() {
                if idx > 0 {
                    kill_all_openvpn_processes().await;
                    tokio::time::sleep(Duration::from_millis(500)).await;
                }

                let processed = preprocess_config_for_driver(config, *strategy);
                std::fs::write(&config_file, &processed).map_err(OpenVpnError::IoError)?;
                debug_log_to_file(&format!(
                    "[DEBUG] Config written for {}: {}",
                    driver_strategy_label(*strategy),
                    config_file.display()
                ));

                let opts = build_service_cli_options(
                    &config_file,
                    &auth_file,
                    &status_file_path,
                    &log_file_path,
                    *strategy,
                );

                diag_log_to_file(&format!(
                    "[RUST_CONNECT] phase=service_ipc_attempt driverStrategy={} workingDir=\"{}\" optsLen={}",
                    driver_strategy_label(*strategy),
                    working_dir,
                    opts.len()
                ));

                match service_ipc::connect_and_launch(&working_dir, &opts, "") {
                    Ok(response) => {
                        let outcome = wait_for_connect_outcome(
                            &log_file_path,
                            response.pid,
                            Duration::from_secs(20),
                        )
                        .await;

                        diag_log_to_file(&format!(
                            "[RUST_CONNECT] phase=service_ipc_ok pid={} desc=\"{}\" driverStrategy={} outcome={:?} elapsedMs={}",
                            response.pid,
                            response.description,
                            driver_strategy_label(*strategy),
                            outcome,
                            connect_started_at.elapsed().as_millis()
                        ));

                        let pid = response.pid;
                        match outcome {
                            ConnectOutcome::Connected | ConnectOutcome::StillRunning => {
                                {
                                    let mut process = self.process.lock().unwrap();
                                    *process = Some(ManagedProcess::Service {
                                        pid,
                                        pipe: response.pipe,
                                    });
                                }
                                self.spawn_log_tailer(
                                    log_file_path.clone(),
                                    pid,
                                    connect_started_at,
                                );
                                used_service = true;
                                active_driver = *strategy;
                                connected = true;
                                break;
                            }
                            ConnectOutcome::DriverFailed
                                if *strategy == DriverStrategy::OvpnDco
                                    && allow_dco_to_tap_fallback =>
                            {
                                stop_service_process(pid, response.pipe).await;
                                diag_log_to_file(
                                    "[RUST_CONNECT] phase=dco_failed fallback=tap-windows6",
                                );
                                continue;
                            }
                            ConnectOutcome::DriverFailed | ConnectOutcome::FatalError => {
                                stop_service_process(pid, response.pipe).await;
                                break;
                            }
                        }
                    }
                    Err(e) => {
                        diag_log_to_file(&format!(
                            "[RUST_CONNECT] phase=service_ipc_failed driverStrategy={} error=\"{}\"",
                            driver_strategy_label(*strategy),
                            e
                        ));
                        if *strategy == DriverStrategy::OvpnDco && allow_dco_to_tap_fallback {
                            continue;
                        }
                        *self.log_file.lock().unwrap() = None;
                    }
                }
            }

            if !connected {
                *self.log_file.lock().unwrap() = None;
            }
        }

        // ── 4. Fallback: direct launch (TAP only — DCO needs service) ───
        // Skip when the install marker says ovpn-dco: no TAP adapter was created.
        if !used_service {
            if preferred_ref == Some("ovpn-dco") {
                return Err(OpenVpnError::ProcessExecutionFailed(
                    "OpenVPN Interactive Service unavailable and preferred_driver=ovpn-dco; \
                     refusing TAP direct fallback (no TAP adapter)"
                        .to_string(),
                ));
            }
            let processed = preprocess_config_for_driver(config, DriverStrategy::TapWindows6);
            std::fs::write(&config_file, &processed).map_err(OpenVpnError::IoError)?;
            self.connect_direct(
                &processed,
                &config_file,
                &auth_file,
                &status_file_path,
                connect_started_at,
            )
            .await?;
            active_driver = DriverStrategy::TapWindows6;
        }

        // ── 5. Spawn status file reader (common) ────────────────────────
        self.spawn_status_reader();

        {
            let mut stats = self.stats.lock().unwrap();
            stats.windows_driver = Some(match active_driver {
                DriverStrategy::OvpnDco => "ovpn-dco".to_string(),
                DriverStrategy::TapWindows6 => "tap-windows6".to_string(),
            });
            stats.windows_connect_mode = Some(
                if used_service {
                    "service".to_string()
                } else {
                    "direct".to_string()
                },
            );
        }

        diag_log_to_file(&format!(
            "[RUST_CONNECT] phase=return_ok mode={} driverStrategy={} elapsedMs={}",
            if used_service { "service" } else { "direct" },
            driver_strategy_label(active_driver),
            connect_started_at.elapsed().as_millis()
        ));

        Ok(())
    }

    // ── Direct launch (existing behaviour) ──────────────────────────────

    async fn connect_direct(
        &self,
        _config: &str,
        config_file: &PathBuf,
        auth_file: &Option<PathBuf>,
        status_file_path: &PathBuf,
        connect_started_at: Instant,
    ) -> Result<(), OpenVpnError> {
        let mut cmd = TokioCommand::new(&self.binary_path);
        cmd.arg("--config").arg(config_file);

        if let Some(ref auth_path) = auth_file {
            cmd.arg("--auth-user-pass").arg(auth_path);
        }

        cmd.arg("--verb").arg("4");

        cmd.arg("--windows-driver").arg("tap-windows6");
        diag_log_to_file("[RUST_CONNECT] driverStrategy=tap-windows6_direct_mode");

        cmd.arg("--status").arg(status_file_path).arg("2");

        cmd.stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::null());

        #[cfg(target_os = "windows")]
        {
            const CREATE_NO_WINDOW: u32 = 0x08000000;
            cmd.creation_flags(CREATE_NO_WINDOW);
        }

        let mut child = cmd.spawn().map_err(|e| {
            OpenVpnError::ProcessExecutionFailed(format!(
                "Failed to spawn OpenVPN process: {}",
                e
            ))
        })?;

        let pid = child.id();
        diag_log_to_file(&format!(
            "[RUST_CONNECT] phase=spawn_ok pid={:?} mode=direct elapsedMs={}",
            pid,
            connect_started_at.elapsed().as_millis()
        ));

        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();

        // stdout reader
        let stage_stdout = Arc::clone(&self.current_stage);
        let stats_stdout = Arc::clone(&self.stats);
        let start_stdout = connect_started_at;
        tokio::spawn(async move {
            let reader = BufReader::new(stdout);
            let mut lines = reader.lines();
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        if let Some(new_stage) = parse_stage_from_output(&line) {
                            let mut current = stage_stdout.lock().unwrap();
                            let old = current.clone();
                            if old != new_stage {
                                log_stage_transition(
                                    "stdout",
                                    &old,
                                    &new_stage,
                                    &line,
                                    start_stdout,
                                );
                                *current = new_stage.clone();
                                if new_stage == "connected" {
                                    let mut stats = stats_stdout.lock().unwrap();
                                    if stats.connected_on.is_none() {
                                        stats.connected_on =
                                            Some(std::time::SystemTime::now());
                                    }
                                }
                            }
                        }
                        parse_stats_from_output(&line, &stats_stdout);
                    }
                    Ok(None) | Err(_) => break,
                }
            }
        });

        // stderr reader
        let stage_stderr = Arc::clone(&self.current_stage);
        let stats_stderr = Arc::clone(&self.stats);
        let start_stderr = connect_started_at;
        tokio::spawn(async move {
            let reader = BufReader::new(stderr);
            let mut lines = reader.lines();
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        debug_log_to_file(&format!("[DEBUG] stderr: {}", line));
                        if let Some(new_stage) = parse_stage_from_output(&line) {
                            let mut current = stage_stderr.lock().unwrap();
                            let old = current.clone();
                            if old != new_stage {
                                log_stage_transition(
                                    "stderr",
                                    &old,
                                    &new_stage,
                                    &line,
                                    start_stderr,
                                );
                                *current = new_stage.clone();
                                if new_stage == "connected" {
                                    let mut stats = stats_stderr.lock().unwrap();
                                    if stats.connected_on.is_none() {
                                        stats.connected_on =
                                            Some(std::time::SystemTime::now());
                                    }
                                }
                            }
                        }
                        parse_stats_from_output(&line, &stats_stderr);
                    }
                    Ok(None) | Err(_) => break,
                }
            }
        });

        // Store the child handle
        {
            let mut process = self.process.lock().unwrap();
            *process = Some(ManagedProcess::Direct(child));
        }

        Ok(())
    }

    // ── Log file tailer task (Service mode) ─────────────────────────────

    fn spawn_log_tailer(
        &self,
        log_path: PathBuf,
        service_pid: u32,
        started_at: Instant,
    ) {
        let log_file_arc = Arc::clone(&self.log_file);
        let stage_arc = Arc::clone(&self.current_stage);
        let stats_arc = Arc::clone(&self.stats);

        // #region agent log
        let log_path_for_dump = log_path.clone();
        // #endregion
        tokio::spawn(async move {
            let mut tailer = service_ipc::LogFileTailer::new(log_path);
            // The interactive service may return before openvpn.exe is fully
            // visible to OpenProcess; avoid a single false-negative death check.
            const PID_ALIVE_GRACE: Duration = Duration::from_secs(15);
            const PID_DEAD_CHECKS_REQUIRED: u32 = 5;
            let mut consecutive_dead_checks: u32 = 0;

            loop {
                tokio::time::sleep(Duration::from_millis(300)).await;

                // Stop signal: log_file set to None by disconnect().
                {
                    let guard = log_file_arc.lock().unwrap();
                    if guard.is_none() {
                        break;
                    }
                }

                for line in tailer.read_new_lines() {
                    if let Some(new_stage) = parse_stage_from_output(&line) {
                        let mut current = stage_arc.lock().unwrap();
                        let old = current.clone();
                        if old != new_stage {
                            log_stage_transition(
                                "log_tailer",
                                &old,
                                &new_stage,
                                &line,
                                started_at,
                            );
                            *current = new_stage.clone();
                            if new_stage == "connected" {
                                let mut stats = stats_arc.lock().unwrap();
                                if stats.connected_on.is_none() {
                                    stats.connected_on =
                                        Some(std::time::SystemTime::now());
                                }
                            }
                        }
                    }
                }

                // Detect process death (after grace period, require consecutive misses).
                if started_at.elapsed() >= PID_ALIVE_GRACE {
                    if service_ipc::is_pid_alive(service_pid) {
                        consecutive_dead_checks = 0;
                    } else {
                        consecutive_dead_checks += 1;
                        diag_log_to_file(&format!(
                            "[RUST_PID_CHECK] pid={} alive=false consecutive={}/{} elapsedMs={}",
                            service_pid,
                            consecutive_dead_checks,
                            PID_DEAD_CHECKS_REQUIRED,
                            started_at.elapsed().as_millis()
                        ));
                        if consecutive_dead_checks >= PID_DEAD_CHECKS_REQUIRED {
                            // #region agent log
                            match std::fs::read_to_string(&log_path_for_dump) {
                                Ok(content) => {
                                    let tail: Vec<&str> =
                                        content.lines().rev().take(50).collect();
                                    let joined: String = tail
                                        .into_iter()
                                        .rev()
                                        .collect::<Vec<&str>>()
                                        .join(" || ");
                                    diag_log_to_file(&format!(
                                        "[RUST_LOG_DUMP] pid={} died; openvpn log tail: {}",
                                        service_pid, joined
                                    ));
                                }
                                Err(e) => diag_log_to_file(&format!(
                                    "[RUST_LOG_DUMP] pid={} died; cannot read log {}: {}",
                                    service_pid,
                                    log_path_for_dump.display(),
                                    e
                                )),
                            }
                            // #endregion
                            let mut current = stage_arc.lock().unwrap();
                            if *current != "connected"
                                && *current != "disconnected"
                                && *current != "disconnecting"
                            {
                                diag_log_to_file(&format!(
                                    "[RUST_STAGE] stream=log_tailer from={} to=error elapsedMs={} reasonCode=PROCESS_DIED trigger=\"PID {} gone\"",
                                    *current,
                                    started_at.elapsed().as_millis(),
                                    service_pid
                                ));
                                *current = "error".to_string();
                            }
                            break;
                        }
                    }
                }
            }
            diag_log_to_file("[RUST_LOG_TAILER] task exited");
        });
    }

    // ── Status file reader task (common) ────────────────────────────────

    fn spawn_status_reader(&self) {
        let stats_arc = Arc::clone(&self.stats);
        let status_file_arc = Arc::clone(&self.status_file);
        let stage_arc = Arc::clone(&self.current_stage);

        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(2)).await;
                let path = {
                    let guard = status_file_arc.lock().unwrap();
                    guard.clone()
                };
                match path {
                    Some(ref p) => {
                        if let Ok(content) = std::fs::read_to_string(p) {
                            parse_status_file(&content, &stats_arc);
                            // Backup connected detection when the log tailer
                            // missed "Initialization Sequence Completed".
                            if content.contains("TUN/TAP read bytes,")
                                && content.contains("END")
                            {
                                let mut current = stage_arc.lock().unwrap();
                                if *current != "connected" && *current != "disconnecting" {
                                    let from_stage = current.clone();
                                    diag_log_to_file(&format!(
                                        "[RUST_STAGE] stream=status_reader from={} to=connected reasonCode=STATUS_TUN_ACTIVE",
                                        from_stage
                                    ));
                                    *current = "connected".to_string();
                                    let mut stats = stats_arc.lock().unwrap();
                                    if stats.connected_on.is_none() {
                                        stats.connected_on =
                                            Some(std::time::SystemTime::now());
                                    }
                                }
                            }
                        }
                    }
                    None => break,
                }
            }
        });
    }

    // ── disconnect ──────────────────────────────────────────────────────

    pub async fn disconnect(&self) -> Result<(), OpenVpnError> {
        debug_log_to_file("[DEBUG] OpenVpnManager::disconnect() called");

        let managed = {
            let mut process = self.process.lock().unwrap();
            process.take()
        };

        match managed {
            Some(ManagedProcess::Direct(mut child)) => {
                kill_all_openvpn_processes().await;
                let _ = child.kill().await;
                let _ = child.wait().await;
                debug_log_to_file("[DEBUG] Direct process cleaned up");
            }
            Some(ManagedProcess::Service { pid, pipe }) => {
                diag_log_to_file(&format!(
                    "[RUST_DISCONNECT] mode=service pid={}",
                    pid
                ));
                stop_service_process(pid, pipe).await;
            }
            None => {
                debug_log_to_file("[DEBUG] No tracked process to disconnect");
            }
        }

        tokio::time::sleep(Duration::from_millis(1500)).await;

        // Clean up temp files
        Self::cleanup_file(&self.config_file);
        Self::cleanup_file(&self.auth_file);
        Self::cleanup_file(&self.status_file);
        Self::cleanup_file(&self.log_file);

        // Reset stage / stats
        *self.current_stage.lock().unwrap() = "disconnected".to_string();
        *self.stats.lock().unwrap() = VpnStats::default();

        Ok(())
    }

    fn cleanup_file(holder: &Arc<Mutex<Option<PathBuf>>>) {
        let mut guard = holder.lock().unwrap();
        if let Some(ref path) = *guard {
            let _ = std::fs::remove_file(path);
        }
        *guard = None;
    }

    // ── Getters ─────────────────────────────────────────────────────────

    pub fn get_stage(&self) -> Result<String, OpenVpnError> {
        let stage = self.current_stage.lock().unwrap().clone();
        debug_log_to_file(&format!("[DEBUG] get_stage() -> {}", stage));
        Ok(stage)
    }

    pub fn get_stats(&self) -> Result<VpnStats, OpenVpnError> {
        Ok(self.stats.lock().unwrap().clone())
    }
}

// ── Output parsing ──────────────────────────────────────────────────────────

fn parse_stage_from_output(line: &str) -> Option<String> {
    let line_lower = line.to_lowercase();

    if line_lower.contains("initialization sequence completed") {
        Some("connected".to_string())
    } else if line_lower.contains("auth_failed")
        || line_lower.contains("authentication failed")
        || line_lower.contains("tls error")
        || line_lower.contains("tls handshake failed")
        || line_lower.contains("cannot resolve host address")
        || line_lower.contains("resolve error")
        || line_lower.contains("network is unreachable")
        || line_lower.contains("connection timed out")
        || line_lower.contains("connection reset")
        || line_lower.contains("connection refused")
        || line_lower.contains("options error")
        || line_lower.contains("fatal")
        || line_lower.contains("certificate verify failed")
        || line_lower.contains("verify error")
    {
        Some("error".to_string())
    } else if line_lower.contains("connecting") || line_lower.contains("waiting") {
        Some("connecting".to_string())
    } else if line_lower.contains("disconnecting") || line_lower.contains("exiting") {
        Some("disconnecting".to_string())
    } else if line_lower.contains("authentication") || line_lower.contains("auth") {
        Some("authenticating".to_string())
    } else if line_lower.contains("preserving previous tun/tap instance") {
        None
    } else if (line_lower.contains("ovpn-dco") || line_lower.contains("tun/tap"))
        && (line_lower.contains("cannot allocate tun/tap")
            || line_lower.contains("error_gen_failure")
            || line_lower.contains("not installed"))
    {
        Some("error".to_string())
    } else if line_lower.contains("register_dns")
        || line_lower.contains("warning:")
        || line_lower.contains("nonfatal")
    {
        // Non-fatal OpenVPN diagnostics (e.g. "Register_dns failed using
        // service") must NOT tear down an already-established tunnel. openvpn
        // keeps running after them. Without this guard the generic error/failed
        // catch-all below flips the stage to `error`, and the app disconnects a
        // perfectly working VPN right after "Initialization Sequence Completed".
        None
    } else if line_lower.contains("error") || line_lower.contains("failed") {
        Some("error".to_string())
    } else {
        None
    }
}

fn parse_stats_from_output(line: &str, stats: &Arc<Mutex<VpnStats>>) {
    let line_lower = line.to_lowercase();

    if line_lower.contains("read bytes") || line_lower.contains("bytes read") {
        if let Some(bytes) = extract_number_after_keyword(&line_lower, "read bytes") {
            stats.lock().unwrap().byte_in = bytes;
        } else if let Some(bytes) = extract_number_after_keyword(&line_lower, "bytes read") {
            stats.lock().unwrap().byte_in = bytes;
        }
    }
    if line_lower.contains("write bytes") || line_lower.contains("bytes write") {
        if let Some(bytes) = extract_number_after_keyword(&line_lower, "write bytes") {
            stats.lock().unwrap().byte_out = bytes;
        } else if let Some(bytes) = extract_number_after_keyword(&line_lower, "bytes write") {
            stats.lock().unwrap().byte_out = bytes;
        }
    }
}

fn parse_status_file(content: &str, stats: &Arc<Mutex<VpnStats>>) {
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty()
            || line.starts_with("OpenVPN STATISTICS")
            || line.starts_with("Updated,")
        {
            continue;
        }
        if let Some(val) = line.strip_prefix("TUN/TAP read bytes,") {
            if let Ok(b) = val.trim().parse::<u64>() {
                stats.lock().unwrap().byte_in = b;
            }
        } else if let Some(val) = line.strip_prefix("TUN/TAP write bytes,") {
            if let Ok(b) = val.trim().parse::<u64>() {
                stats.lock().unwrap().byte_out = b;
            }
        } else if let Some(val) = line.strip_prefix("TCP/UDP read bytes,") {
            if let Ok(b) = val.trim().parse::<u64>() {
                stats.lock().unwrap().byte_in = b;
            }
        } else if let Some(val) = line.strip_prefix("TCP/UDP write bytes,") {
            if let Ok(b) = val.trim().parse::<u64>() {
                stats.lock().unwrap().byte_out = b;
            }
        }
    }
}

fn extract_number_after_keyword(line: &str, keyword: &str) -> Option<u64> {
    let pos = line.find(keyword)?;
    let after = &line[pos + keyword.len()..];
    let number_str: String = after
        .chars()
        .skip_while(|c| !c.is_ascii_digit())
        .take_while(|c| c.is_ascii_digit() || *c == ',')
        .filter(|c| c.is_ascii_digit())
        .collect();
    if number_str.is_empty() {
        None
    } else {
        number_str.parse::<u64>().ok()
    }
}
