#import "OpenvpnFlutterPlugin.h"
#if __has_include(<openvpn_flutter/openvpn_flutter-Swift.h>)
#import <openvpn_flutter/openvpn_flutter-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "openvpn_flutter-Swift.h"
#endif

@implementation OpenVPNFlutterPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftOpenVPNFlutterPlugin registerWithRegistrar:registrar];
}
@end
