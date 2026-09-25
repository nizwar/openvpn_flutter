//! Global OpenVPN manager (thread-safe singleton)
//!
//! The inner `Arc<OpenVpnManager>` allows callers to clone a handle and release
//! the outer lock immediately, so long-running operations (connect / disconnect)
//! never block stage reads from the polling thread.

use std::sync::{Arc, Mutex, OnceLock};
use crate::openvpn::OpenVpnManager;
use crate::error::OpenVpnError;

static MANAGER: OnceLock<Arc<Mutex<Option<Arc<OpenVpnManager>>>>> = OnceLock::new();

/// Initializes the global manager
pub fn init_manager(binary_path: String) -> Result<(), OpenVpnError> {
    let manager = Arc::new(OpenVpnManager::new(binary_path)?);
    let global = MANAGER.get_or_init(|| Arc::new(Mutex::new(None)));
    let mut mgr = global.lock().unwrap();
    *mgr = Some(manager);
    Ok(())
}

/// Gets the global manager
pub fn get_manager() -> Result<Arc<Mutex<Option<Arc<OpenVpnManager>>>>, OpenVpnError> {
    MANAGER.get()
        .ok_or_else(|| OpenVpnError::ConfigurationError(
            "Manager not initialized".to_string()
        ))
        .map(|m| Arc::clone(m))
}

