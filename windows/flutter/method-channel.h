// STUB FILE - Pour le linter uniquement
// Les vrais headers sont dans flutter/ephemeral/ lors de la compilation Windows
// Ce fichier permet au linter de ne pas afficher d'erreurs

#ifndef FLUTTER_METHOD_CHANNEL_H_
#define FLUTTER_METHOD_CHANNEL_H_

#include <memory>
#include <string>
#include <functional>
#include "encodable_value.h"

namespace flutter {

template<typename T>
class MethodChannel {
public:
    MethodChannel(void* messenger, const std::string& name, void* codec) {}
    void SetMethodCallHandler(std::function<void(const MethodCall<T>&, std::unique_ptr<MethodResult<T>>)> handler) {}
};

} // namespace flutter

#endif // FLUTTER_METHOD_CHANNEL_H_

