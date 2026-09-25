//! Rust library for managing OpenVPN on Windows via FFI
//! 
//! This library exposes FFI functions to be called from Dart
//! via the Flutter Windows plugin.

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;
use std::io::Write;
use std::sync::{Arc, OnceLock};

use tokio::runtime::Runtime;

mod openvpn;
mod error;
mod manager;
mod service_ipc;

pub use openvpn::{OpenVpnManager, VpnStats};
pub use error::*;
pub use manager::*;

// Set to true to enable debug logging
const ENABLE_DEBUG_LOGS: bool = false;

// Macro helper for debug logging
macro_rules! debug_log {
    ($($arg:tt)*) => {
        if ENABLE_DEBUG_LOGS {
            eprintln!($($arg)*);
        }
    };
}

// Global Tokio runtime to keep async tasks (stdout/stderr readers) alive
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn get_runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        Runtime::new().expect("Failed to create Tokio runtime for OpenVPN")
    })
}

/// Structure to represent VPN state
#[repr(C)]
pub struct VpnState {
    pub stage: *const c_char,  // Current stage (connected, disconnected, etc.)
    pub connected_on: *const c_char,  // ISO8601 connection timestamp
    pub byte_in: u64,
    pub byte_out: u64,
    pub packets_in: u64,
    pub packets_out: u64,
    pub windows_driver: *const c_char,
    pub windows_connect_mode: *const c_char,
}

impl Default for VpnState {
    fn default() -> Self {
        VpnState {
            stage: ptr::null(),
            connected_on: ptr::null(),
            byte_in: 0,
            byte_out: 0,
            packets_in: 0,
            packets_out: 0,
            windows_driver: ptr::null(),
            windows_connect_mode: ptr::null(),
        }
    }
}

/// Initializes the OpenVPN manager
/// 
/// # Safety
/// This function is unsafe because it manipulates C pointers
#[no_mangle]
pub unsafe extern "C" fn openvpn_initialize(
    binary_path: *const c_char,
) -> c_int {
    // Write to file immediately to verify FFI is called
    if ENABLE_DEBUG_LOGS {
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(std::env::temp_dir().join("openvpn_rust_debug.log"))
        {
            let _ = writeln!(file, "[DEBUG] openvpn_initialize() called from FFI");
            let _ = file.flush();
        }
    }
    debug_log!("[DEBUG] openvpn_initialize() called");
    if binary_path.is_null() {
        debug_log!("[DEBUG] openvpn_initialize: ERROR - null binary_path");
        return -1; // Error: null path
    }

    let path = match CStr::from_ptr(binary_path).to_str() {
        Ok(s) => {
            debug_log!("[DEBUG] openvpn_initialize: binary_path = '{}'", s);
            s
        },
        Err(_) => {
            debug_log!("[DEBUG] openvpn_initialize: ERROR - UTF-8 conversion failed");
            return -2; // Error: UTF-8 conversion
        }
    };

    debug_log!("[DEBUG] openvpn_initialize: Calling init_manager()");
    match manager::init_manager(path.to_string()) {
        Ok(_) => {
            debug_log!("[DEBUG] openvpn_initialize: SUCCESS");
            0 // Success
        },
        Err(e) => {
            debug_log!("[DEBUG] openvpn_initialize: ERROR - initialization failed: {:?}", e);
            -3 // Error: initialization failed
        }
    }
}

/// Connects to VPN with the provided configuration
/// 
/// # Safety
/// This function is unsafe because it manipulates C pointers
#[no_mangle]
pub unsafe extern "C" fn openvpn_connect(
    config: *const c_char,
    username: *const c_char,
    password: *const c_char,
) -> c_int {
    debug_log!("[DEBUG] openvpn_connect() called");
    if config.is_null() {
        debug_log!("[DEBUG] openvpn_connect: ERROR - null config");
        return -1; // Error: null config
    }

    let config_str = match CStr::from_ptr(config).to_str() {
        Ok(s) => {
            debug_log!("[DEBUG] openvpn_connect: config length = {} bytes", s.len());
            s
        },
        Err(_) => {
            debug_log!("[DEBUG] openvpn_connect: ERROR - config UTF-8 conversion failed");
            return -2;
        }
    };

    let username_str = if !username.is_null() {
        match CStr::from_ptr(username).to_str() {
            Ok(s) => {
                debug_log!("[DEBUG] openvpn_connect: username = '{}'", s);
                Some(s.to_string())
            },
            Err(_) => {
                debug_log!("[DEBUG] openvpn_connect: ERROR - username UTF-8 conversion failed");
                return -3;
            }
        }
    } else {
        debug_log!("[DEBUG] openvpn_connect: username is null");
        None
    };

    let password_str = if !password.is_null() {
        match CStr::from_ptr(password).to_str() {
            Ok(s) => {
                debug_log!("[DEBUG] openvpn_connect: password provided (length = {})", s.len());
                Some(s.to_string())
            },
            Err(_) => {
                debug_log!("[DEBUG] openvpn_connect: ERROR - password UTF-8 conversion failed");
                return -4;
            }
        }
    } else {
        debug_log!("[DEBUG] openvpn_connect: password is null");
        None
    };

    // Get the global manager
    debug_log!("[DEBUG] openvpn_connect: Getting global manager");
    let manager = {
        let manager_arc = match manager::get_manager() {
            Ok(m) => {
                debug_log!("[DEBUG] openvpn_connect: Manager retrieved");
                m
            },
            Err(e) => {
                debug_log!("[DEBUG] openvpn_connect: ERROR - Manager not initialized: {:?}", e);
                return -5;
            }
        };
        let guard = manager_arc.lock().unwrap();
        match guard.as_ref() {
            Some(m) => Arc::clone(m),
            None => {
                debug_log!("[DEBUG] openvpn_connect: ERROR - Manager is None");
                return -6;
            }
        }
        // guard dropped here – outer lock released immediately
    };

    debug_log!("[DEBUG] openvpn_connect: Manager acquired, using global Tokio runtime");
    let rt = get_runtime();

    debug_log!("[DEBUG] openvpn_connect: Calling manager.connect()");
    match rt.block_on(manager.connect(config_str, username_str, password_str)) {
        Ok(_) => {
            debug_log!("[DEBUG] openvpn_connect: SUCCESS");
            0
        },
        Err(e) => {
            debug_log!("[DEBUG] openvpn_connect: ERROR - Connection failed: {:?}", e);
            -7
        }
    }
}

/// Disconnects from VPN
/// 
/// # Safety
/// This function is unsafe because it manipulates C pointers
#[no_mangle]
pub unsafe extern "C" fn openvpn_disconnect() -> c_int {
    let manager = {
        let manager_arc = match manager::get_manager() {
            Ok(m) => m,
            Err(_) => return -1,
        };
        let guard = manager_arc.lock().unwrap();
        match guard.as_ref() {
            Some(m) => Arc::clone(m),
            None => return -1,
        }
        // guard dropped here – outer lock released immediately
    };

    let rt = get_runtime();
    match rt.block_on(manager.disconnect()) {
        Ok(_) => 0,
        Err(_) => -3,
    }
}

/// Gets the current VPN stage
/// 
/// Returns an allocated C string that must be freed with openvpn_free_string
/// 
/// # Safety
/// This function is unsafe because it manipulates C pointers
#[no_mangle]
pub unsafe extern "C" fn openvpn_get_stage() -> *mut c_char {
    debug_log!("[DEBUG] openvpn_get_stage() called");
    let manager = {
        let manager_arc = match manager::get_manager() {
            Ok(m) => m,
            Err(_) => {
                debug_log!("[DEBUG] openvpn_get_stage: Manager not initialized, returning 'disconnected'");
                return CString::new("disconnected").unwrap().into_raw();
            }
        };
        let guard = manager_arc.lock().unwrap();
        match guard.as_ref() {
            Some(m) => Arc::clone(m),
            None => {
                debug_log!("[DEBUG] openvpn_get_stage: Manager is None, returning 'disconnected'");
                return CString::new("disconnected").unwrap().into_raw();
            }
        }
    };

    match manager.get_stage() {
        Ok(stage) => {
            debug_log!("[DEBUG] openvpn_get_stage: Returning stage '{}'", stage);
            CString::new(stage).unwrap_or_else(|_| {
                debug_log!("[DEBUG] openvpn_get_stage: ERROR creating CString, returning 'disconnected'");
                CString::new("disconnected").unwrap()
            }).into_raw()
        },
        Err(e) => {
            debug_log!("[DEBUG] openvpn_get_stage: ERROR getting stage: {:?}, returning 'disconnected'", e);
            CString::new("disconnected").unwrap().into_raw()
        }
    }
}

/// Gets the current VPN status
/// 
/// Returns a VpnState structure that must be freed with openvpn_free_state
/// 
/// # Safety
/// This function is unsafe because it manipulates C pointers
#[no_mangle]
pub unsafe extern "C" fn openvpn_get_status() -> *mut VpnState {
    let manager = {
        let manager_arc = match manager::get_manager() {
            Ok(m) => m,
            Err(_) => {
                let state = Box::new(VpnState::default());
                return Box::into_raw(state);
            }
        };
        let guard = manager_arc.lock().unwrap();
        match guard.as_ref() {
            Some(m) => Arc::clone(m),
            None => {
                let state = Box::new(VpnState::default());
                return Box::into_raw(state);
            }
        }
    };

    match manager.get_stats() {
        Ok(stats) => {
            let stage_str = manager.get_stage().unwrap_or_else(|_| "disconnected".to_string());
            let stage_cstr = CString::new(stage_str).unwrap_or_else(|_| {
                CString::new("disconnected").unwrap()
            });

            let connected_on_str = if let Some(connected_on) = stats.connected_on {
                match connected_on.duration_since(std::time::UNIX_EPOCH) {
                    Ok(duration) => {
                        let datetime = chrono::DateTime::<chrono::Utc>::from_timestamp(
                            duration.as_secs() as i64,
                            duration.subsec_nanos(),
                        );
                        datetime.map(|dt| dt.to_rfc3339()).unwrap_or_default()
                    },
                    Err(_) => String::new(),
                }
            } else {
                String::new()
            };

            let connected_on_cstr = if connected_on_str.is_empty() {
                ptr::null()
            } else {
                match CString::new(connected_on_str) {
                    Ok(s) => s.into_raw() as *const c_char,
                    Err(_) => ptr::null(),
                }
            };

            let stage_ptr = stage_cstr.into_raw();

            let windows_driver_cstr = stats
                .windows_driver
                .as_ref()
                .and_then(|s| CString::new(s.as_str()).ok());
            let windows_driver_ptr = windows_driver_cstr
                .map(|s| s.into_raw() as *const c_char)
                .unwrap_or(ptr::null());

            let windows_connect_mode_cstr = stats
                .windows_connect_mode
                .as_ref()
                .and_then(|s| CString::new(s.as_str()).ok());
            let windows_connect_mode_ptr = windows_connect_mode_cstr
                .map(|s| s.into_raw() as *const c_char)
                .unwrap_or(ptr::null());

            let state = Box::new(VpnState {
                stage: stage_ptr as *const c_char,
                connected_on: connected_on_cstr,
                byte_in: stats.byte_in,
                byte_out: stats.byte_out,
                packets_in: stats.packets_in,
                packets_out: stats.packets_out,
                windows_driver: windows_driver_ptr,
                windows_connect_mode: windows_connect_mode_ptr,
            });

            Box::into_raw(state)
        },
        Err(_) => {
            let state = Box::new(VpnState::default());
            Box::into_raw(state)
        }
    }
}

/// Frees a C string allocated by the library
/// 
/// # Safety
/// This function is unsafe because it manipulates C pointers
#[no_mangle]
pub unsafe extern "C" fn openvpn_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        let _ = CString::from_raw(ptr);
    }
}

/// Frees a VpnState structure allocated by the library
/// 
/// # Safety
/// This function is unsafe because it manipulates C pointers
#[no_mangle]
pub unsafe extern "C" fn openvpn_free_state(ptr: *mut VpnState) {
    if !ptr.is_null() {
        let state = Box::from_raw(ptr);
        
        // Free C strings if they are not null
        if !state.stage.is_null() {
            // Free the stage string
            let _ = CString::from_raw(state.stage as *mut c_char);
        }
        
        if !state.connected_on.is_null() {
            // Free the connected_on string
            let _ = CString::from_raw(state.connected_on as *mut c_char);
        }

        if !state.windows_driver.is_null() {
            let _ = CString::from_raw(state.windows_driver as *mut c_char);
        }

        if !state.windows_connect_mode.is_null() {
            let _ = CString::from_raw(state.windows_connect_mode as *mut c_char);
        }
    }
}

