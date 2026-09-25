#ifndef OPENVPN_FLUTTER_PLUGIN_H_
#define OPENVPN_FLUTTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter_plugin_registrar.h>

#include <memory>
#include <string>
#include <thread>
#include <atomic>
#include <chrono>
#include <mutex>

namespace flutter {

class OpenvpnFlutterPlugin : public Plugin {
 public:
  static void RegisterWithRegistrar(PluginRegistrarWindows *registrar);

  OpenvpnFlutterPlugin();

  virtual ~OpenvpnFlutterPlugin();

 private:
  void HandleMethodCall(
      const MethodCall<EncodableValue> &method_call,
      std::unique_ptr<MethodResult<EncodableValue>> result);
  
  void SetupEventChannel(PluginRegistrarWindows *registrar);
  void EmitCurrentStage();  // Checks and emits current stage if different
  void StartStagePolling();  // Start polling for stage changes
  void StopStagePolling();   // Stop polling for stage changes
  void StagePollingThread(); // Thread function for polling
  void EmitStageIfChanged(const std::string& stage, const char* source);

  std::unique_ptr<MethodChannel<EncodableValue>> method_channel_;
  std::unique_ptr<EventChannel<EncodableValue>> event_channel_;
  std::unique_ptr<EventSink<EncodableValue>> event_sink_;
  std::string last_emitted_stage_;  // Last emitted stage to avoid duplicates
  std::mutex stage_mutex_;
  std::thread stage_polling_thread_;  // Thread for polling stage changes
  std::atomic<bool> stop_polling_;    // Flag to stop polling
};

}  // namespace flutter

// C API export function
extern "C" __declspec(dllexport) void OpenvpnFlutterPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#endif  // OPENVPN_FLUTTER_PLUGIN_H_

