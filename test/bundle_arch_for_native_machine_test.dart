import 'package:flutter_test/flutter_test.dart';
import 'package:openvpn_flutter/src/windows_binary_manager.dart';

void main() {
  group('bundleArchForNativeMachine', () {
    test('maps IMAGE_FILE_MACHINE_ARM64 to arm64', () {
      expect(bundleArchForNativeMachine(imageFileMachineArm64), 'arm64');
      expect(bundleArchForNativeMachine(0xAA64), 'arm64');
    });

    test('maps IMAGE_FILE_MACHINE_AMD64 to x64', () {
      expect(bundleArchForNativeMachine(imageFileMachineAmd64), 'x64');
      expect(bundleArchForNativeMachine(0x8664), 'x64');
    });

    test('maps unknown / other machines to x64', () {
      expect(bundleArchForNativeMachine(0), 'x64');
      expect(bundleArchForNativeMachine(0x014C), 'x64'); // I386
    });
  });
}
