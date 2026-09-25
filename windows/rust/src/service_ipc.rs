//! IPC client for the OpenVPN Interactive Service on Windows.
//!
//! The service listens on `\\.\pipe\openvpn\service` and expects a startup
//! buffer of 3 concatenated UTF-16 null-terminated strings:
//!   1. working directory
//!   2. CLI options for openvpn.exe
//!   3. stdin data (can be empty)
//!
//! It responds with 3 UTF-16 lines separated by `\n`:
//!   1. hex error code (`0x00000000` on success)
//!   2. PID (hex) or second error code
//!   3. human-readable description

use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;

#[cfg(target_os = "windows")]
mod win32 {
    use std::os::raw::c_void;

    pub type HANDLE = *mut c_void;
    pub type DWORD = u32;
    pub type BOOL = i32;
    pub type LPCWSTR = *const u16;

    pub const INVALID_HANDLE_VALUE: HANDLE = -1isize as HANDLE;
    pub const GENERIC_READ: DWORD = 0x80000000;
    pub const GENERIC_WRITE: DWORD = 0x40000000;
    pub const OPEN_EXISTING: DWORD = 3;
    pub const ERROR_ACCESS_DENIED: DWORD = 5;
    pub const ERROR_PIPE_BUSY: DWORD = 231;
    pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
    pub const PIPE_READMODE_MESSAGE: DWORD = 0x00000002;

    extern "system" {
        pub fn CreateFileW(
            lpFileName: LPCWSTR,
            dwDesiredAccess: DWORD,
            dwShareMode: DWORD,
            lpSecurityAttributes: *mut c_void,
            dwCreationDisposition: DWORD,
            dwFlagsAndAttributes: DWORD,
            hTemplateFile: HANDLE,
        ) -> HANDLE;

        pub fn WriteFile(
            hFile: HANDLE,
            lpBuffer: *const c_void,
            nNumberOfBytesToWrite: DWORD,
            lpNumberOfBytesWritten: *mut DWORD,
            lpOverlapped: *mut c_void,
        ) -> BOOL;

        pub fn ReadFile(
            hFile: HANDLE,
            lpBuffer: *mut c_void,
            nNumberOfBytesToRead: DWORD,
            lpNumberOfBytesRead: *mut DWORD,
            lpOverlapped: *mut c_void,
        ) -> BOOL;

        pub fn CloseHandle(hObject: HANDLE) -> BOOL;

        pub fn WaitNamedPipeW(lpNamedPipeName: LPCWSTR, nTimeOut: DWORD) -> BOOL;

        pub fn GetLastError() -> DWORD;

        pub fn OpenProcess(
            dwDesiredAccess: DWORD,
            bInheritHandle: BOOL,
            dwProcessId: DWORD,
        ) -> HANDLE;

        pub fn SetNamedPipeHandleState(
            hNamedPipe: HANDLE,
            lpMode: *mut DWORD,
            lpMaxCollectionCount: *mut DWORD,
            lpCollectDataTimeout: *mut DWORD,
        ) -> BOOL;

        pub fn Sleep(dwMilliseconds: DWORD);
    }
}

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub enum ServiceIpcError {
    ServiceUnavailable(String),
    StartupRejected { code: u32, message: String },
    InvalidResponse(String),
    IoError(std::io::Error),
}

impl std::fmt::Display for ServiceIpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ServiceUnavailable(msg) => write!(f, "Service unavailable: {}", msg),
            Self::StartupRejected { code, message } => {
                write!(f, "Startup rejected (0x{:08X}): {}", code, message)
            }
            Self::InvalidResponse(msg) => write!(f, "Invalid response: {}", msg),
            Self::IoError(e) => write!(f, "IO error: {}", e),
        }
    }
}

impl std::error::Error for ServiceIpcError {}

// ---------------------------------------------------------------------------
// Response
// ---------------------------------------------------------------------------

pub struct ServiceResponse {
    pub pid: u32,
    pub description: String,
    /// Client end of the service pipe. The Interactive Service terminates the
    /// launched `openvpn.exe` as soon as this handle is closed, so it must be
    /// kept alive for the whole connection; dropping it *is* the disconnect.
    pub pipe: ServicePipe,
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const PIPE_NAME: &str = r"\\.\pipe\openvpn\service";
const PIPE_CONNECT_TIMEOUT_MS: u32 = 1000;
const PIPE_READ_BUFFER_SIZE: usize = 4096;

// ---------------------------------------------------------------------------
// RAII handle wrapper
// ---------------------------------------------------------------------------

/// Owned client handle on the Interactive Service pipe; closed on drop.
#[cfg(target_os = "windows")]
pub struct ServicePipe(win32::HANDLE);

// The handle is only ever closed once (Drop) and never dereferenced; it is
// safe to move it to the task that owns the connection.
#[cfg(target_os = "windows")]
unsafe impl Send for ServicePipe {}
#[cfg(target_os = "windows")]
unsafe impl Sync for ServicePipe {}

#[cfg(target_os = "windows")]
impl Drop for ServicePipe {
    fn drop(&mut self) {
        unsafe {
            win32::CloseHandle(self.0);
        }
    }
}

#[cfg(not(target_os = "windows"))]
pub struct ServicePipe;

// ---------------------------------------------------------------------------
// UTF-16 helpers
// ---------------------------------------------------------------------------

fn encode_utf16_nul(s: &str) -> Vec<u8> {
    let wide: Vec<u16> = s.encode_utf16().chain(std::iter::once(0u16)).collect();
    wide.iter().flat_map(|w| w.to_le_bytes()).collect()
}

#[cfg(target_os = "windows")]
fn to_wide_nul(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0u16)).collect()
}

// ---------------------------------------------------------------------------
// Main IPC function
// ---------------------------------------------------------------------------

/// Connect to the OpenVPN Interactive Service pipe, send startup data, and
/// return the PID of the launched `openvpn.exe`.
#[cfg(target_os = "windows")]
pub fn connect_and_launch(
    working_dir: &str,
    cli_options: &str,
    stdin_data: &str,
) -> Result<ServiceResponse, ServiceIpcError> {
    use win32::*;

    let pipe_wide = to_wide_nul(PIPE_NAME);

    // Retry loop: the service pipe may be momentarily busy between clients.
    const MAX_RETRIES: u32 = 2;
    let mut handle: HANDLE = INVALID_HANDLE_VALUE;

    for attempt in 0..MAX_RETRIES {
        handle = unsafe {
            CreateFileW(
                pipe_wide.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                std::ptr::null_mut(),
                OPEN_EXISTING,
                0,
                std::ptr::null_mut(),
            )
        };

        if handle != INVALID_HANDLE_VALUE {
            break;
        }

        let err = unsafe { GetLastError() };
        if err == ERROR_PIPE_BUSY {
            // Wait for an instance to become available, then retry.
            unsafe {
                WaitNamedPipeW(pipe_wide.as_ptr(), PIPE_CONNECT_TIMEOUT_MS);
                // Small extra sleep to let the service recycle the instance.
                Sleep(200);
            }
        } else {
            return Err(ServiceIpcError::ServiceUnavailable(format!(
                "CreateFileW failed on attempt {}, error={}",
                attempt, err
            )));
        }
    }

    if handle == INVALID_HANDLE_VALUE {
        return Err(ServiceIpcError::ServiceUnavailable(format!(
            "Pipe still busy after {} retries ({}ms each)",
            MAX_RETRIES, PIPE_CONNECT_TIMEOUT_MS
        )));
    }

    let pipe = ServicePipe(handle);

    // The Interactive Service creates a MESSAGE-mode pipe; switch the client
    // handle to MESSAGE read mode so ReadFile returns one message at a time.
    unsafe {
        let mut mode: DWORD = PIPE_READMODE_MESSAGE;
        SetNamedPipeHandleState(pipe.0, &mut mode, std::ptr::null_mut(), std::ptr::null_mut());
    }

    // Build startup data: 3 null-terminated UTF-16 strings concatenated.
    let mut buf = Vec::new();
    buf.extend_from_slice(&encode_utf16_nul(working_dir));
    buf.extend_from_slice(&encode_utf16_nul(cli_options));
    buf.extend_from_slice(&encode_utf16_nul(stdin_data));

    // Write startup data
    unsafe {
        let mut written: DWORD = 0;
        if WriteFile(
            pipe.0,
            buf.as_ptr() as *const _,
            buf.len() as DWORD,
            &mut written,
            std::ptr::null_mut(),
        ) == 0
        {
            return Err(ServiceIpcError::IoError(std::io::Error::from_raw_os_error(
                GetLastError() as i32,
            )));
        }
    }

    // Read response
    let mut read_buf = vec![0u8; PIPE_READ_BUFFER_SIZE];
    let bytes_read = unsafe {
        let mut n: DWORD = 0;
        if ReadFile(
            pipe.0,
            read_buf.as_mut_ptr() as *mut _,
            read_buf.len() as DWORD,
            &mut n,
            std::ptr::null_mut(),
        ) == 0
        {
            return Err(ServiceIpcError::IoError(std::io::Error::from_raw_os_error(
                GetLastError() as i32,
            )));
        }
        n as usize
    };

    if bytes_read < 2 {
        return Err(ServiceIpcError::InvalidResponse("Empty response".into()));
    }

    // Decode UTF-16LE
    let wide_slice: &[u16] = unsafe {
        std::slice::from_raw_parts(read_buf.as_ptr() as *const u16, bytes_read / 2)
    };
    let response_text = String::from_utf16_lossy(wide_slice);

    let parsed = parse_service_response(&response_text)?;
    Ok(ServiceResponse {
        pid: parsed.pid,
        description: parsed.description,
        pipe,
    })
}

// ---------------------------------------------------------------------------
// Response parser
// ---------------------------------------------------------------------------

struct ParsedResponse {
    pid: u32,
    description: String,
}

fn parse_service_response(text: &str) -> Result<ParsedResponse, ServiceIpcError> {
    let lines: Vec<&str> = text.lines().collect();
    if lines.len() < 3 {
        return Err(ServiceIpcError::InvalidResponse(format!(
            "Expected 3 lines, got {}: {:?}",
            lines.len(),
            text
        )));
    }

    let error_code =
        u32::from_str_radix(lines[0].trim().trim_start_matches("0x"), 16).unwrap_or(0xFFFFFFFF);

    if error_code != 0 {
        return Err(ServiceIpcError::StartupRejected {
            code: error_code,
            message: lines[2].trim().to_string(),
        });
    }

    let pid = u32::from_str_radix(lines[1].trim().trim_start_matches("0x"), 16).map_err(|_| {
        ServiceIpcError::InvalidResponse(format!("Cannot parse PID from '{}'", lines[1]))
    })?;

    Ok(ParsedResponse {
        pid,
        description: lines[2].trim().to_string(),
    })
}

// ---------------------------------------------------------------------------
// Service availability probe
// ---------------------------------------------------------------------------

/// Returns `true` when the Interactive Service pipe exists (service is running).
#[cfg(target_os = "windows")]
pub fn is_service_available() -> bool {
    let pipe_wide = to_wide_nul(PIPE_NAME);
    let ok = unsafe { win32::WaitNamedPipeW(pipe_wide.as_ptr(), 0) };
    if ok != 0 {
        return true;
    }
    // ERROR_SEM_TIMEOUT (121) or ERROR_PIPE_BUSY (231) still mean the pipe exists.
    let err = unsafe { win32::GetLastError() };
    err == 121 || err == win32::ERROR_PIPE_BUSY
}

// ---------------------------------------------------------------------------
// PID liveness check
// ---------------------------------------------------------------------------

/// Returns `true` when the given PID still represents a running process.
///
/// `openvpn.exe` launched by the Interactive Service may not be openable from
/// an unprivileged caller; ERROR_ACCESS_DENIED still proves the process exists.
#[cfg(target_os = "windows")]
pub fn is_pid_alive(pid: u32) -> bool {
    let handle = unsafe {
        win32::OpenProcess(win32::PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
    };
    if handle.is_null() {
        return unsafe { win32::GetLastError() } == win32::ERROR_ACCESS_DENIED;
    }
    unsafe {
        win32::CloseHandle(handle);
    }
    true
}

// ---------------------------------------------------------------------------
// Log file tailer
// ---------------------------------------------------------------------------

/// Reads new complete lines appended to a log file since the last call.
pub struct LogFileTailer {
    path: PathBuf,
    last_pos: u64,
}

impl LogFileTailer {
    pub fn new(path: PathBuf) -> Self {
        Self { path, last_pos: 0 }
    }

    /// Return any new *complete* lines (terminated by `\n`) since the last call.
    pub fn read_new_lines(&mut self) -> Vec<String> {
        let mut file = match std::fs::File::open(&self.path) {
            Ok(f) => f,
            Err(_) => return vec![],
        };

        let file_len = match file.metadata() {
            Ok(m) => m.len(),
            Err(_) => return vec![],
        };

        if file_len <= self.last_pos {
            return vec![];
        }

        if file.seek(SeekFrom::Start(self.last_pos)).is_err() {
            return vec![];
        }

        let to_read = (file_len - self.last_pos) as usize;
        let mut buf = vec![0u8; to_read];
        let n = match file.read(&mut buf) {
            Ok(n) => n,
            Err(_) => return vec![],
        };
        buf.truncate(n);

        // Only process up to the last newline to avoid partial lines.
        let process_len = match buf.iter().rposition(|&b| b == b'\n') {
            Some(pos) => pos + 1,
            None => return vec![],
        };

        self.last_pos += process_len as u64;

        let text = String::from_utf8_lossy(&buf[..process_len]);
        text.lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.to_string())
            .collect()
    }
}

// ---------------------------------------------------------------------------
// Non-Windows stubs
// ---------------------------------------------------------------------------

#[cfg(not(target_os = "windows"))]
pub fn connect_and_launch(
    _working_dir: &str,
    _cli_options: &str,
    _stdin_data: &str,
) -> Result<ServiceResponse, ServiceIpcError> {
    Err(ServiceIpcError::ServiceUnavailable(
        "Not supported on this platform".into(),
    ))
}

#[cfg(not(target_os = "windows"))]
pub fn is_service_available() -> bool {
    false
}

#[cfg(not(target_os = "windows"))]
pub fn is_pid_alive(_pid: u32) -> bool {
    false
}
