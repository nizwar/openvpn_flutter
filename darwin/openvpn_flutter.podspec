#
# iOS and macOS share this implementation (sharedDarwinSource). The OpenVPN
# engine runs in the app's packet tunnel provider, see the README.
#
Pod::Spec.new do |s|
  s.name             = 'openvpn_flutter'
  s.version          = '2.0.1'
  s.summary          = 'OpenVPN for Flutter'
  s.description      = <<-DESC
Connects Flutter apps to OpenVPN servers through a NetworkExtension packet tunnel provider.
                       DESC
  s.homepage         = 'https://github.com/nizwar/openvpn_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Laskarmedia' => 'nizwar@laskarmedia.id' }
  s.source           = { :path => '.' }
  # Keep CocoaPods and Swift Package Manager building the same source tree.
  s.source_files     = 'openvpn_flutter/Sources/openvpn_flutter/**/*.swift'
  s.resource_bundles = { 'openvpn_flutter_privacy' => ['openvpn_flutter/Sources/openvpn_flutter/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'NetworkExtension'

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '12.0'
  # Packet tunnels of Developer ID apps are System Extensions (10.15+).
  s.osx.deployment_target = '10.15'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
