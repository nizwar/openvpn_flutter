// STUB FILE - Pour le linter uniquement
// Les vrais headers sont dans flutter/ephemeral/ lors de la compilation Windows

#ifndef FLUTTER_PLUGIN_REGISTRAR_WINDOWS_H_
#define FLUTTER_PLUGIN_REGISTRAR_WINDOWS_H_

#include <memory>

namespace flutter {

class PluginRegistrarWindows {
public:
    void* messenger() { return nullptr; }
    void AddPlugin(std::unique_ptr<void> plugin) {}
};

typedef void* FlutterDesktopPluginRegistrarRef;

class PluginRegistrarManager {
public:
    static PluginRegistrarManager* GetInstance() { return nullptr; }
    template<typename T>
    T* GetRegistrar(FlutterDesktopPluginRegistrarRef ref) { return nullptr; }
};

} // namespace flutter

#endif // FLUTTER_PLUGIN_REGISTRAR_WINDOWS_H_

