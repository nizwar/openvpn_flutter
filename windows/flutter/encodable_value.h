// STUB FILE - Pour le linter uniquement
// Les vrais headers sont dans flutter/ephemeral/ lors de la compilation Windows

#ifndef FLUTTER_ENCODABLE_VALUE_H_
#define FLUTTER_ENCODABLE_VALUE_H_

#include <string>
#include <map>
#include <vector>
#include <variant>
#include <memory>

namespace flutter {

// Stub pour EncodableValue
using EncodableValue = std::variant<
    std::nullptr_t,
    bool,
    int32_t,
    int64_t,
    double,
    std::string,
    std::vector<uint8_t>,
    std::vector<EncodableValue>,
    std::map<std::string, EncodableValue>
>;

using EncodableMap = std::map<std::string, EncodableValue>;
using EncodableList = std::vector<EncodableValue>;

template<typename T>
class MethodCall {
public:
    const std::string& method_name() const { static std::string s; return s; }
    const EncodableValue* arguments() const { return nullptr; }
};

template<typename T>
class MethodResult {
public:
    void Success(const T& value) {}
    void Error(const std::string& code, const std::string& message) {}
    void NotImplemented() {}
};

} // namespace flutter

#endif // FLUTTER_ENCODABLE_VALUE_H_

