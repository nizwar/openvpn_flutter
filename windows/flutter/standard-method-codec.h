// STUB FILE - Pour le linter uniquement
// Les vrais headers sont dans flutter/ephemeral/ lors de la compilation Windows

#ifndef FLUTTER_STANDARD_METHOD_CODEC_H_
#define FLUTTER_STANDARD_METHOD_CODEC_H_

namespace flutter {

class StandardMethodCodec {
public:
    static StandardMethodCodec& GetInstance() {
        static StandardMethodCodec instance;
        return instance;
    }
};

} // namespace flutter

#endif // FLUTTER_STANDARD_METHOD_CODEC_H_

