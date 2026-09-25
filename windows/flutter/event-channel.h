// STUB FILE - Pour le linter uniquement
// Les vrais headers sont dans flutter/ephemeral/ lors de la compilation Windows

#ifndef FLUTTER_EVENT_CHANNEL_H_
#define FLUTTER_EVENT_CHANNEL_H_

#include <memory>
#include <string>
#include <functional>
#include "encodable_value.h"

namespace flutter {

template<typename T>
class StreamHandlerError {
public:
    StreamHandlerError() {}
};

template<typename T>
class EventSink {
public:
    void Success(const T& value) {}
    void Error(const std::string& code, const std::string& message, const T* details = nullptr) {}
};

template<typename T>
class StreamHandler {
public:
    StreamHandler(std::function<std::unique_ptr<StreamHandlerError<T>>(const T*, std::unique_ptr<EventSink<T>>&&)> onListen,
                  std::function<std::unique_ptr<StreamHandlerError<T>>(const T*)> onCancel) {}
};

template<typename T>
class EventChannel {
public:
    EventChannel(void* messenger, const std::string& name, void* codec) {}
    void SetStreamHandler(std::unique_ptr<StreamHandler<T>> handler) {}
};

} // namespace flutter

#endif // FLUTTER_EVENT_CHANNEL_H_

