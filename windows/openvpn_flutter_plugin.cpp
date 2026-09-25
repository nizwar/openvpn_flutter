#include "openvpn_flutter_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <sstream>
#include <map>
#include <string>
#include <optional>
#include <cstring>
#include <fstream>
#include <cstdlib>

// Set to true to enable debug logging
const bool ENABLE_DEBUG_LOGS = false;

// Debug logging macro for Windows
#define DEBUG_LOG(msg) do { \
    if (ENABLE_DEBUG_LOGS) { \
        std::string log_msg = "[DEBUG C++] "; \
        log_msg += msg; \
        log_msg += "\n"; \
        OutputDebugStringA(log_msg.c_str()); \
    } \
} while(0)

#define DEBUG_LOG_FMT(fmt, ...) do { \
    if (ENABLE_DEBUG_LOGS) { \
        char buf[1024]; \
        snprintf(buf, sizeof(buf), "[DEBUG C++] " fmt "\n", __VA_ARGS__); \
        OutputDebugStringA(buf); \
    } \
} while(0)

// VpnState structure from Rust
struct VpnState {
    const char* stage;
    const char* connected_on;
    uint64_t byte_in;
    uint64_t byte_out;
    uint64_t packets_in;
    uint64_t packets_out;
    const char* windows_driver;
    const char* windows_connect_mode;
};

// FFI Rust function declarations
extern "C" {
    int openvpn_initialize(const char* binary_path);
    int openvpn_connect(const char* config, const char* username, const char* password);
    int openvpn_disconnect();
    char* openvpn_get_stage();
    VpnState* openvpn_get_status();
    void openvpn_free_string(char* ptr);
    void openvpn_free_state(VpnState* ptr);
}

namespace flutter {

namespace {

std::optional<std::string> GetEnvironmentVariable(const char* name) {
  char* value = nullptr;
  size_t value_length = 0;
  const errno_t result = _dupenv_s(&value, &value_length, name);
  if (result != 0 || value == nullptr) {
    return std::nullopt;
  }

  std::string environment_value(value);
  std::free(value);
  return environment_value;
}

void WriteDiagLog(const std::string& msg) {
  const auto temp_dir = GetEnvironmentVariable("TEMP");
  if (!temp_dir.has_value()) return;
  std::string log_path = *temp_dir + "\\openvpn_cpp_diag.log";
  std::ofstream log_file(log_path, std::ios::app | std::ios::binary);
  if (log_file.is_open()) {
    log_file << msg << std::endl;
    log_file.flush();
  }
}

}  // namespace

// static
void OpenvpnFlutterPlugin::RegisterWithRegistrar(
    PluginRegistrarWindows *registrar) {
  // Log plugin registration
  const auto temp_dir = GetEnvironmentVariable("TEMP");
  if (temp_dir.has_value()) {
    std::string log_path = *temp_dir + "\\openvpn_cpp_debug.log";
    std::ofstream log_file(log_path, std::ios::app | std::ios::binary);
    if (log_file.is_open()) {
      log_file << "[DEBUG C++] RegisterWithRegistrar called" << std::endl;
      log_file.flush();
      log_file.close();
    }
  }
  
  auto plugin = std::make_unique<OpenvpnFlutterPlugin>();
  
  plugin->method_channel_ =
      std::make_unique<MethodChannel<EncodableValue>>(
          registrar->messenger(), "id.laskarmedia.openvpn_flutter/vpncontrol",
          &StandardMethodCodec::GetInstance());

  plugin->method_channel_->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  plugin->SetupEventChannel(registrar);
  
  registrar->AddPlugin(std::move(plugin));
  
  // Log plugin registration complete
  if (temp_dir.has_value()) {
    std::string log_path = *temp_dir + "\\openvpn_cpp_debug.log";
    std::ofstream log_file(log_path, std::ios::app | std::ios::binary);
    if (log_file.is_open()) {
      log_file << "[DEBUG C++] RegisterWithRegistrar complete" << std::endl;
      log_file.flush();
      log_file.close();
    }
  }
}

OpenvpnFlutterPlugin::OpenvpnFlutterPlugin() : last_emitted_stage_("disconnected"), stop_polling_(false) {}

OpenvpnFlutterPlugin::~OpenvpnFlutterPlugin() {
  StopStagePolling();
}

void OpenvpnFlutterPlugin::EmitStageIfChanged(const std::string& stage,
                                              const char* source) {
  std::lock_guard<std::mutex> lock(stage_mutex_);
  if (stage == last_emitted_stage_) {
    return;
  }
  const std::string previous = last_emitted_stage_;
  last_emitted_stage_ = stage;
  WriteDiagLog("[CPP_STAGE] source=" + std::string(source) + " from=" + previous +
               " to=" + stage);
  if (event_sink_) {
    event_sink_->Success(EncodableValue(stage));
  }
}

void OpenvpnFlutterPlugin::SetupEventChannel(
    PluginRegistrarWindows *registrar) {
  event_channel_ =
      std::make_unique<EventChannel<EncodableValue>>(
          registrar->messenger(), "id.laskarmedia.openvpn_flutter/vpnstage",
          &StandardMethodCodec::GetInstance());

  auto event_handler = std::make_unique<
      StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue* arguments,
             std::unique_ptr<EventSink<EncodableValue>>&& events)
          -> std::unique_ptr<StreamHandlerError<EncodableValue>> {
        std::lock_guard<std::mutex> lock(this->stage_mutex_);
        this->event_sink_ = std::move(events);
        return nullptr;
      },
      [this](const EncodableValue* arguments)
          -> std::unique_ptr<StreamHandlerError<EncodableValue>> {
        std::lock_guard<std::mutex> lock(this->stage_mutex_);
        this->event_sink_.reset();
        return nullptr;
      });

  event_channel_->SetStreamHandler(std::move(event_handler));
}

void OpenvpnFlutterPlugin::HandleMethodCall(
    const MethodCall<EncodableValue> &method_call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  
  const std::string& method = method_call.method_name();
  DEBUG_LOG_FMT("HandleMethodCall: method = '%s'", method.c_str());

  // Also write to file to be sure we see it
  const auto temp_dir = GetEnvironmentVariable("TEMP");
  if (temp_dir.has_value()) {
    std::string log_path = *temp_dir + "\\openvpn_cpp_debug.log";
    std::ofstream log_file(log_path, std::ios::app | std::ios::binary);
    if (log_file.is_open()) {
      log_file << "[DEBUG C++] HandleMethodCall: method = " << method << std::endl;
      log_file.flush();
      log_file.close();
    }
  }

  if (method == "initialize") {
    DEBUG_LOG("HandleMethodCall: initialize called");
    const auto* args = std::get_if<EncodableMap>(method_call.arguments());
    if (!args) {
      result->Error("InvalidArguments", "Expected map");
      return;
    }

    // For Windows, we need the path to openvpn.exe
    // We can get it from WindowsBinaryManager on the Dart side
    // Note: iOS parameters (groupIdentifier, etc.) are not required for Windows
    std::string binary_path;
    auto it = args->find(EncodableValue("binaryPath"));
    if (it != args->end()) {
      const auto* path_value = std::get_if<std::string>(&it->second);
      if (path_value) {
        binary_path = *path_value;
      }
    }

    if (binary_path.empty()) {
      DEBUG_LOG("HandleMethodCall: initialize - ERROR: binaryPath is empty");
      result->Error("InvalidArguments", "binaryPath is required for Windows");
      return;
    }

    DEBUG_LOG_FMT("HandleMethodCall: initialize - binary_path = '%s'", binary_path.c_str());
    int ret = openvpn_initialize(binary_path.c_str());
    DEBUG_LOG_FMT("HandleMethodCall: initialize - openvpn_initialize returned %d", ret);
    if (ret == 0) {
      DEBUG_LOG("HandleMethodCall: initialize - SUCCESS");
      result->Success(EncodableValue("disconnected"));
    } else {
      std::string error_msg = "Failed to initialize OpenVPN (error code: " + std::to_string(ret) + ")";
      DEBUG_LOG_FMT("HandleMethodCall: initialize - ERROR: %s", error_msg.c_str());
      result->Error("InitializationFailed", error_msg);
    }
  } else if (method == "connect") {
    DEBUG_LOG("HandleMethodCall: connect called");
    const auto* args = std::get_if<EncodableMap>(method_call.arguments());
    if (!args) {
      DEBUG_LOG("HandleMethodCall: connect - ERROR: Expected map");
      result->Error("InvalidArguments", "Expected map");
      return;
    }

    std::string config;
    std::string username;
    std::string password;

    auto config_it = args->find(EncodableValue("config"));
    if (config_it != args->end()) {
      const auto* config_value = std::get_if<std::string>(&config_it->second);
      if (config_value) {
        config = *config_value;
      }
    }

    auto username_it = args->find(EncodableValue("username"));
    if (username_it != args->end()) {
      const auto* username_value = std::get_if<std::string>(&username_it->second);
      if (username_value) {
        username = *username_value;
      }
    }

    auto password_it = args->find(EncodableValue("password"));
    if (password_it != args->end()) {
      const auto* password_value = std::get_if<std::string>(&password_it->second);
      if (password_value) {
        password = *password_value;
      }
    }

    DEBUG_LOG_FMT("HandleMethodCall: connect - config length = %zu", config.length());
    DEBUG_LOG_FMT("HandleMethodCall: connect - username provided = %s", username.empty() ? "NO" : "YES");
    DEBUG_LOG_FMT("HandleMethodCall: connect - password provided = %s", password.empty() ? "NO" : "YES");

    if (config.empty()) {
      DEBUG_LOG("HandleMethodCall: connect - ERROR: config is empty");
      result->Error("InvalidArguments", "config is required");
      return;
    }

    // Return immediately so the UI thread is never blocked.
    // The actual FFI call runs on a background thread; the polling
    // thread will pick up stage transitions (connecting → connected).
    DEBUG_LOG("HandleMethodCall: connect - returning immediately, spawning bg thread");
    result->Success(nullptr);
    StartStagePolling();

    std::string cfg = config;
    std::string usr = username;
    std::string pwd = password;
    std::thread([cfg, usr, pwd]() {
        openvpn_connect(
            cfg.c_str(),
            usr.empty() ? nullptr : usr.c_str(),
            pwd.empty() ? nullptr : pwd.c_str()
        );
    }).detach();
  } else if (method == "disconnect") {
    // Return immediately so the UI thread is never blocked.
    result->Success(nullptr);

    // Emit "disconnecting" right away so the UI can update.
    EmitStageIfChanged("disconnecting", "disconnect_method");

    // Ensure polling is running to detect the final "disconnected" stage
    // set by the Rust side once cleanup is done.
    StartStagePolling();

    std::thread([]() {
        openvpn_disconnect();
    }).detach();
  } else if (method == "stage") {
    DEBUG_LOG("HandleMethodCall: stage called");
    char* stage = openvpn_get_stage();
    if (stage) {
      std::string stage_str(stage);
      DEBUG_LOG_FMT("HandleMethodCall: stage - got stage '%s'", stage_str.c_str());
      openvpn_free_string(stage);
      result->Success(EncodableValue(stage_str));
      EmitStageIfChanged(stage_str, "stage_method");
    } else {
      DEBUG_LOG("HandleMethodCall: stage - stage is null, returning 'disconnected'");
      result->Success(EncodableValue("disconnected"));
    }
  } else if (method == "status") {
    // Get status from Rust
    VpnState* state = openvpn_get_status();
    if (state) {
      // Build JSON
      std::ostringstream json;
      json << "{";
      
      // connected_on
      if (state->connected_on && strlen(state->connected_on) > 0) {
        json << "\"connected_on\":\"" << state->connected_on << "\",";
      } else {
        json << "\"connected_on\":null,";
      }
      
      // Statistics
      json << "\"byte_in\":\"" << state->byte_in << "\",";
      json << "\"byte_out\":\"" << state->byte_out << "\",";
      json << "\"packets_in\":\"" << state->packets_in << "\",";
      json << "\"packets_out\":\"" << state->packets_out << "\"";

      if (state->windows_driver && strlen(state->windows_driver) > 0) {
        json << ",\"windows_driver\":\"" << state->windows_driver << "\"";
      }

      if (state->windows_connect_mode && strlen(state->windows_connect_mode) > 0) {
        json << ",\"windows_connect_mode\":\"" << state->windows_connect_mode << "\"";
      }
      
      json << "}";
      
      std::string status_json = json.str();
      
      // Free the structure
      openvpn_free_state(state);
      
      result->Success(EncodableValue(status_json));
    } else {
      // On error, return empty status
      std::string status_json = "{\"connected_on\":null,\"byte_in\":\"0\",\"byte_out\":\"0\",\"packets_in\":\"0\",\"packets_out\":\"0\"}";
      result->Success(EncodableValue(status_json));
    }
  } else {
    result->NotImplemented();
  }
}

void OpenvpnFlutterPlugin::EmitCurrentStage() {
  DEBUG_LOG("EmitCurrentStage() called");
  char* stage = openvpn_get_stage();
  if (stage) {
    std::string stage_str(stage);
    DEBUG_LOG_FMT("EmitCurrentStage: got stage '%s'", stage_str.c_str());
    openvpn_free_string(stage);
    
    EmitStageIfChanged(stage_str, "emit_current_stage");
  } else {
    DEBUG_LOG("EmitCurrentStage: stage is null");
  }
}

void OpenvpnFlutterPlugin::StartStagePolling() {
  DEBUG_LOG("StartStagePolling() called");
  StopStagePolling();  // Stop any existing polling
  stop_polling_ = false;
  stage_polling_thread_ = std::thread(&OpenvpnFlutterPlugin::StagePollingThread, this);
  DEBUG_LOG("StartStagePolling: polling thread started");
}

void OpenvpnFlutterPlugin::StopStagePolling() {
  DEBUG_LOG("StopStagePolling() called");
  if (stop_polling_) {
    return;  // Already stopped
  }
  stop_polling_ = true;
  if (stage_polling_thread_.joinable()) {
    stage_polling_thread_.join();
    DEBUG_LOG("StopStagePolling: polling thread stopped");
  }
}

void OpenvpnFlutterPlugin::StagePollingThread() {
  DEBUG_LOG("StagePollingThread: started");
  while (!stop_polling_) {
    // Check stage every 500ms
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    
    if (stop_polling_) {
      break;
    }
    
    // Get current stage from Rust
    char* stage = openvpn_get_stage();
    if (stage) {
      std::string stage_str(stage);
      openvpn_free_string(stage);
      
      // Never emit from this worker thread: Flutter platform channels must be
      // invoked on the platform thread. Windows Dart side now polls `stage()`.
      WriteDiagLog("[CPP_STAGE] source=stage_polling_thread observed=" + stage_str);
    }
  }
  DEBUG_LOG("StagePollingThread: ended");
}

}  // namespace flutter

void OpenvpnFlutterPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter::OpenvpnFlutterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

