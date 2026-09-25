import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show FlutterError, debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:crypto/crypto.dart' show sha256;

/// IMAGE_FILE_MACHINE_ARM64 — native machine returned by [IsWow64Process2].
const int imageFileMachineArm64 = 0xAA64;

/// IMAGE_FILE_MACHINE_AMD64 — PE machine for x64 kernel drivers.
const int imageFileMachineAmd64 = 0x8664;

/// Maps an [IsWow64Process2] native-machine value to the OpenVPN asset bundle
/// folder (`arm64` or `x64`). Pure function — unit-tested without FFI.
String bundleArchForNativeMachine(int nativeMachine) {
  if (nativeMachine == imageFileMachineArm64) {
    return 'arm64';
  }
  return 'x64';
}

/// Manages download, verification and storage of openvpn.exe for Windows
class WindowsBinaryManager {
  /// Target OpenVPN version (to be updated according to official releases)
  /// See: https://github.com/OpenVPN/openvpn/releases
  static const String targetVersion = '2.7.5';

  static String? _cachedWindowsArch;
  static int? _cachedNativeMachine;
  static int? _cachedProcessMachine;

  /// Windows OS (kernel) architecture used to select native binaries and
  /// drivers (`x64` or `arm64`).
  ///
  /// Resolved via [IsWow64Process2] so an x64 process under emulation on
  /// Windows on ARM still picks the ARM64 driver/OpenVPN bundle. The Flutter
  /// app and Rust DLL remain x64 (process arch); only openvpn.exe, OpenSSL
  /// DLLs, tapctl and kernel drivers follow the kernel.
  static String get windowsArch {
    return _cachedWindowsArch ??= _resolveWindowsArch();
  }

  /// Native machine value from the last [IsWow64Process2] query (cached).
  static int? get nativeMachine => _cachedNativeMachine;

  /// Process machine value from the last [IsWow64Process2] query (cached).
  static int? get processMachine => _cachedProcessMachine;

  /// Expected PE `Machine` for `.sys` drivers that must match the kernel.
  static int get expectedDriverPeMachine =>
      windowsArch == 'arm64' ? imageFileMachineArm64 : imageFileMachineAmd64;

  static String _resolveWindowsArch() {
    if (!Platform.isWindows) {
      return 'x64';
    }
    try {
      final machines = _queryWow64Machines();
      if (machines != null) {
        _cachedProcessMachine = machines[0];
        _cachedNativeMachine = machines[1];
        return bundleArchForNativeMachine(machines[1]);
      }
    } catch (e) {
      debugPrint(
        '[WindowsBinaryManager] IsWow64Process2 failed ($e); '
        'falling back to environment',
      );
    }
    return _windowsArchFromEnvironment();
  }

  /// Fallback when [IsWow64Process2] is unavailable (pre-Windows 10 1709).
  static String _windowsArchFromEnvironment() {
    final effective =
        (Platform.environment['PROCESSOR_ARCHITEW6432'] ??
                Platform.environment['PROCESSOR_ARCHITECTURE'] ??
                '')
            .toUpperCase();
    if (effective.contains('ARM64') || effective.contains('AARCH64')) {
      return 'arm64';
    }
    return 'x64';
  }

  /// Returns `[processMachine, nativeMachine]` or null on API failure.
  static List<int>? _queryWow64Machines() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getCurrentProcess = kernel32.lookupFunction<IntPtr Function(),
        int Function()>('GetCurrentProcess');
    final isWow64Process2 = kernel32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint16>, Pointer<Uint16>),
        int Function(int, Pointer<Uint16>, Pointer<Uint16>)>('IsWow64Process2');

    final processMachine = calloc<Uint16>();
    final nativeMachine = calloc<Uint16>();
    try {
      final ok = isWow64Process2(
        getCurrentProcess(),
        processMachine,
        nativeMachine,
      );
      if (ok == 0) {
        return null;
      }
      return <int>[processMachine.value, nativeMachine.value];
    } finally {
      calloc.free(processMachine);
      calloc.free(nativeMachine);
    }
  }

  /// Path to the embedded OpenVPN binary asset inside the Flutter bundle,
  /// scoped to the current OS architecture subfolder (`x64` or `arm64`).
  /// Override the file located at `assets/openvpn/windows/<arch>/openvpn.exe.bin`
  /// with a trusted executable before distributing the app.
  /// Note: For plugin assets, the path must include 'packages/plugin_name/'
  static String get embeddedAssetPath =>
      'packages/openvpn_flutter/assets/openvpn/windows/$windowsArch/openvpn.exe.bin';

  /// Indicates whether we should attempt to deploy the embedded asset before
  /// falling back to the legacy download mechanism.
  static const bool preferEmbeddedBinary = true;

  /// MSI architecture token used by the official OpenVPN Windows installers
  /// (`amd64` for x64, `arm64` for ARM64).
  static String get _msiArchToken => windowsArch == 'arm64' ? 'arm64' : 'amd64';

  /// Base URL to download the official OpenVPN MSI installer (fallback only).
  ///
  /// The primary distribution mechanism is the embedded, pre-extracted binary
  /// asset (see [preferEmbeddedBinary]). This URL is only used as a last-resort
  /// fallback and must be extracted with `msiexec /a` to obtain `openvpn.exe`.
  /// Architecture-specific: `amd64` or `arm64`.
  static String get baseDownloadUrl =>
      'https://build.openvpn.net/downloads/releases/'
      'OpenVPN-$targetVersion-I001-$_msiArchToken.msi';

  /// Expected SHA256 hash of the embedded `openvpn.exe`, keyed by architecture.
  ///
  /// Fill these with the SHA256 of the pre-extracted binaries staged under
  /// `assets/openvpn/windows/<arch>/openvpn.exe.bin` (see
  /// `tool/fetch_openvpn_binaries.ps1`). Leave `null` to skip verification.
  static const Map<String, String?> _expectedHashByArch = {
    'x64': '49FF9582D272BC72F39DAB8D34E092508D6900557C6D5309C118B26B7033394F',
    'arm64': '7D8072BF9D1F02AA454141D1044A9E9F3FB9D6187F8ED88509347EE359F4E0D5',
  };

  /// Expected SHA256 hash of the embedded `openvpn.exe` for the current OS arch.
  static String? get expectedHash => _expectedHashByArch[windowsArch];

  /// Indicates whether the downloaded file is an MSI installer (true) or a standalone binary (false)
  static const bool isInstaller = true;

  /// Binary file name
  static const String binaryName = 'openvpn.exe';

  /// Interactive Service binary (launches openvpn.exe as SYSTEM via named pipe).
  static const String interactiveServiceBinaryName = 'openvpnserv.exe';

  /// Message DLL used by the Interactive Service for event-log entries.
  static const String interactiveServiceMsgDll = 'openvpnservmsg.dll';

  /// SHA256 of the embedded `openvpnserv.exe`, keyed by architecture.
  ///
  /// Fill with the SHA256 of the staged
  /// `assets/openvpn/windows/<arch>/openvpnserv.exe.bin`. Leave `null` to skip.
  static const Map<String, String?> _expectedInteractiveServiceHashByArch = {
    'x64': 'B04E2159E5A38DBD7C4510BF9431AE36B4C6E4954D0EA4B10F1321B90C54C6B2',
    'arm64': '0B18387EB2B9C79EBAAC6DA1340FBB5D02CC9ACF22FCF949882BD2CDCBBFFE47',
  };

  /// SHA256 of the embedded `openvpnserv.exe` for the current OS architecture.
  static String? get expectedInteractiveServiceHash =>
      _expectedInteractiveServiceHashByArch[windowsArch];

  /// Subfolder under the OpenVPN runtime directory for `.ovpn` configs.
  static const String configSubdir = 'config';

  /// Subfolder for OpenVPN log files (service mode).
  static const String logSubdir = 'log';

  /// Subfolder for OpenVPN status files.
  static const String statusSubdir = 'status';

  /// Preferred driver marker written by elevated driver setup (`ovpn-dco` or
  /// `tap-windows6`). Absent on installs that predate the marker.
  static const String preferredDriverFileName = 'preferred_driver.txt';

  /// Machine-wide OpenVPN root under `%ProgramData%` (accessible to LocalSystem).
  /// Actual runtime paths append [windowsArch] (`LavControl/OpenVPN/<arch>`).
  static const String machineRuntimeFolder = 'LavControl/OpenVPN';

  /// Version file name
  static const String versionFileName = 'openvpn_version.txt';

  /// Hash file name
  static const String hashFileName = 'openvpn_sha256.txt';

  /// OpenVPN runtime dependencies required by openvpn.exe on Windows.
  ///
  /// The OpenSSL DLLs are architecture-specific and named accordingly by the
  /// official installer (`-x64` on amd64, `-arm64` on ARM64), while the
  /// pkcs11-helper DLL keeps the same name on all architectures.
  static List<String> get requiredRuntimeDlls {
    final suffix = windowsArch == 'arm64' ? 'arm64' : 'x64';
    return [
      'libcrypto-3-$suffix.dll',
      'libssl-3-$suffix.dll',
      'libpkcs11-helper-1.dll',
    ];
  }

  /// Plugin asset base paths (package and direct paths), scoped to the current
  /// OS architecture subfolder (`x64` or `arm64`).
  static List<String> get _assetBasePaths => [
        'packages/openvpn_flutter/assets/openvpn/windows/$windowsArch',
        'assets/openvpn/windows/$windowsArch',
      ];

  /// Environment variable allowing to override the binary path for debugging.
  ///
  /// If this variable is set (e.g. to a system-installed openvpn.exe),
  /// the manager will use that path directly instead of deploying the
  /// embedded asset or downloading anything.
  static const String overrideEnvVar = 'OPENVPN_WINDOWS_BINARY_OVERRIDE';

  /// Gets the storage directory for openvpn.exe (per-user staging, per arch).
  static Future<Directory> _getStorageDirectory() async {
    final appSupportDir = await getApplicationSupportDirectory();
    final openvpnDir = Directory(
      path.join(appSupportDir.path, 'openvpn', windowsArch),
    );
    if (!await openvpnDir.exists()) {
      await openvpnDir.create(recursive: true);
    }
    return openvpnDir;
  }

  /// Directory where OpenVPN runtime binaries are stored (per-user staging).
  static Future<Directory> getRuntimeDirectory() => _getStorageDirectory();

  /// Machine-wide directory for the Interactive Service and shared config/log.
  ///
  /// Layout: `%ProgramData%/LavControl/OpenVPN/<arch>` so an ARM host that
  /// previously staged x64 binaries does not reuse them.
  static Future<String> getMachineRuntimeDirectory() async {
    final programData =
        Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    final dir = Directory(
      path.joinAll([
        programData,
        ...machineRuntimeFolder.split('/'),
        windowsArch,
      ]),
    );
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {
        // Elevated install creates this directory with proper ACLs.
      }
    }
    return dir.path;
  }

  /// Full path to [preferredDriverFileName] under the machine runtime dir.
  static Future<String> getPreferredDriverMarkerPath() async {
    final machineDir = await getMachineRuntimeDirectory();
    return path.join(machineDir, preferredDriverFileName);
  }

  /// Directory approved by the Interactive Service for `.ovpn` configs.
  static Future<String> getConfigDirectory() async {
    final machineDir = await getMachineRuntimeDirectory();
    final configDir = Directory(path.join(machineDir, configSubdir));
    if (!await configDir.exists()) {
      try {
        await configDir.create(recursive: true);
      } catch (_) {
        // Created during elevated service install.
      }
    }
    return configDir.path;
  }

  /// Full path to the deployed Interactive Service binary (machine-wide).
  static Future<String> getInteractiveServicePath() async {
    final machineDir = await getMachineRuntimeDirectory();
    return path.join(machineDir, interactiveServiceBinaryName);
  }

  /// Staging path for the Interactive Service binary (per-user AppData).
  static Future<String> getInteractiveServiceStagingPath() async {
    final dir = await _getStorageDirectory();
    return path.join(dir.path, interactiveServiceBinaryName);
  }

  /// Gets the full path to openvpn.exe
  static Future<String> getBinaryPath() async {
    // Debug override: allow using a system-installed binary
    final overridePath = Platform.environment[overrideEnvVar];
    if (overridePath != null && overridePath.isNotEmpty) {
      return overridePath;
    }

    final dir = await _getStorageDirectory();
    return path.join(dir.path, binaryName);
  }

  /// Checks if openvpn.exe exists locally
  static Future<bool> binaryExists() async {
    final binaryPath = await getBinaryPath();
    final file = File(binaryPath);
    return await file.exists();
  }

  /// Gets the locally installed version
  static Future<String?> getInstalledVersion() async {
    final dir = await _getStorageDirectory();
    final versionFile = File(path.join(dir.path, versionFileName));
    if (await versionFile.exists()) {
      try {
        return await versionFile.readAsString();
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  /// Saves the installed version
  static Future<void> _saveInstalledVersion(String version) async {
    final dir = await _getStorageDirectory();
    final versionFile = File(path.join(dir.path, versionFileName));
    await versionFile.writeAsString(version);
  }

  /// Calculates the SHA256 hash of a file
  static Future<String> calculateFileHash(File file) async {
    final bytes = await file.readAsBytes();
    final hash = sha256.convert(bytes);
    return hash.toString();
  }

  /// Checks if an update is needed
  static Future<bool> needsUpdate() async {
    final installedVersion = await getInstalledVersion();
    if (installedVersion == null) return true;
    return installedVersion != targetVersion;
  }

  /// Downloads the OpenVPN installer from GitHub Releases
  ///
  /// NOTE: If [isInstaller] is true, the downloaded file is an MSI that must be extracted.
  /// This method only downloads the installer. Extraction must be handled separately.
  ///
  /// [onProgress] optional callback to track progress (0.0 to 1.0)
  /// Returns the path to the downloaded file (MSI or exe depending on source)
  static Future<String> downloadBinary({
    Function(double progress)? onProgress,
  }) async {
    final dir = await _getStorageDirectory();
    final binaryPath = path.join(dir.path, binaryName);
    final file = File(binaryPath);

    try {
      // Download the file
      final response = await http.get(
        Uri.parse(baseDownloadUrl),
      );

      if (response.statusCode != 200) {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      // Write the file
      await file.writeAsBytes(response.bodyBytes);

      // Verify that the file exists and is not empty
      if (!await file.exists() || await file.length() == 0) {
        throw Exception('Downloaded file is empty or invalid');
      }

      // If it's an MSI installer, note that extraction will be necessary
      if (isInstaller && binaryPath.endsWith('.exe')) {
        // The downloaded file is the installer, not the final binary
        // Extraction will need to be handled by a separate method
      }

      await _verifyHash(file);

      // If it's an installer, extract openvpn.exe
      if (isInstaller) {
        final extractedPath = await _extractFromInstaller(file.path);
        // Replace the installer file with the extracted binary
        if (extractedPath != null && await File(extractedPath).exists()) {
          final sourceDirectoryPath = path.dirname(extractedPath);
          final targetDirectoryPath = path.dirname(binaryPath);
          await file.delete(); // Delete the installer
          await File(extractedPath).copy(binaryPath); // Copy the binary
          await _copyRuntimeDllsFromDirectory(
            sourceDirectoryPath: sourceDirectoryPath,
            targetDirectoryPath: targetDirectoryPath,
            failIfMissing: true,
          );
          await _deployInteractiveServiceBinaries(
            Directory(targetDirectoryPath),
          );
          await File(extractedPath).delete(); // Clean up temporary file
        } else {
          throw Exception('Failed to extract openvpn.exe from installer');
        }
      }

      // Save the version
      await _saveInstalledVersion(targetVersion);

      await _persistHashFile();

      return binaryPath;
    } catch (e) {
      // Clean up on error
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    }
  }

  /// Checks and downloads openvpn.exe if necessary
  ///
  /// [forceUpdate] forces download even if a version already exists
  /// [onProgress] optional callback to track progress
  /// Returns the path to openvpn.exe (downloaded or existing)
  static Future<String> ensureBinary({
    bool forceUpdate = false,
    Function(double progress)? onProgress,
  }) async {
    final binaryPath = await getBinaryPath();

    // If an override is set, don't try to deploy or download anything.
    final overridePath = Platform.environment[overrideEnvVar];
    if (overridePath != null && overridePath.isNotEmpty) {
      final file = File(overridePath);
      if (await file.exists()) {
        debugPrint(
          '[WindowsBinaryManager] Using override OpenVPN binary from $overridePath',
        );
        return overridePath;
      } else {
        debugPrint(
          '[WindowsBinaryManager] Override path $overridePath does not exist; '
          'falling back to embedded/deployed binary.',
        );
      }
    }

    if (await binaryExists()) {
      if (!forceUpdate) {
        final needsUpdate = await WindowsBinaryManager.needsUpdate();
        if (!needsUpdate) {
          await _ensureRuntimeDependenciesForExistingBinary(binaryPath);
          return binaryPath;
        }
      }
      await _deleteExistingArtifacts();
    }

    Exception? embeddedError;
    if (preferEmbeddedBinary) {
      try {
        final deployed = await _deployEmbeddedBinary(onProgress: onProgress);
        if (deployed) {
          return binaryPath;
        }
        // If deployed is false, asset was not found
        embeddedError = Exception(
          'Le binaire OpenVPN embarqué n\'a pas pu être déployé. '
          'Vérifiez que le fichier assets/openvpn/windows/openvpn.exe.bin existe '
          'et est inclus dans le build de l\'application.'
        );
      } catch (e) {
        embeddedError =
            Exception('Échec du déploiement du binaire OpenVPN embarqué: $e');
      }
    }

    // If embedded binary failed and we prefer it, don't try to download
    if (preferEmbeddedBinary && embeddedError != null) {
      throw Exception(
        'Impossible d\'utiliser le binaire OpenVPN embarqué. '
        'Le téléchargement automatique est désactivé. '
        'Erreur: ${embeddedError.toString()}'
      );
    }

    try {
      return await downloadBinary(onProgress: onProgress);
    } catch (e) {
      if (embeddedError != null) {
        throw Exception(
          '${embeddedError.toString()}\nLe téléchargement de secours a également échoué: $e',
        );
      }
      rethrow;
    }
  }

  /// Checks binary execution permissions
  static Future<bool> checkPermissions() async {
    if (!Platform.isWindows) {
      return false;
    }

    final binaryPath = await getBinaryPath();
    final file = File(binaryPath);

    if (!await file.exists()) {
      return false;
    }

    // Check that the file is executable
    // On Windows, we just check existence and read permissions
    try {
      final stat = await file.stat();
      return stat.size > 0;
    } catch (e) {
      return false;
    }
  }

  /// Deletes the binary and associated files
  static Future<void> cleanup() async {
    final dir = await _getStorageDirectory();
    final binaryFile = File(path.join(dir.path, binaryName));
    final versionFile = File(path.join(dir.path, versionFileName));
    final hashFile = File(path.join(dir.path, hashFileName));

    if (await binaryFile.exists()) {
      await binaryFile.delete();
    }
    if (await versionFile.exists()) {
      await versionFile.delete();
    }
    if (await hashFile.exists()) {
      await hashFile.delete();
    }

    for (final dllName in requiredRuntimeDlls) {
      final dllFile = File(path.join(dir.path, dllName));
      if (await dllFile.exists()) {
        await dllFile.delete();
      }
    }
    for (final fileName in [
      interactiveServiceBinaryName,
      interactiveServiceMsgDll,
    ]) {
      final file = File(path.join(dir.path, fileName));
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  static Future<void> _deleteExistingArtifacts() async {
    final dir = await _getStorageDirectory();
    final filesToDelete = [
      path.join(dir.path, binaryName),
      path.join(dir.path, versionFileName),
      path.join(dir.path, hashFileName),
      // Force redeploy of the Interactive Service binaries on version change so
      // they never lag behind openvpn.exe (version mismatch breaks service IPC).
      path.join(dir.path, interactiveServiceBinaryName),
      path.join(dir.path, interactiveServiceMsgDll),
      ...requiredRuntimeDlls.map((dll) => path.join(dir.path, dll)),
    ];
    for (final filePath in filesToDelete) {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  static Future<void> _persistHashFile() async {
    if (expectedHash == null) return;
    final dir = await _getStorageDirectory();
    final hashFile = File(path.join(dir.path, hashFileName));
    await hashFile.writeAsString(expectedHash!);
  }

  static Future<void> _verifyHash(File file) async {
    if (expectedHash == null) return;
    final actualHash = await calculateFileHash(file);
    if (actualHash.toLowerCase() != expectedHash!.toLowerCase()) {
      await file.delete();
      throw Exception('OpenVPN binary hash mismatch. '
          'Expected: $expectedHash, Received: $actualHash');
    }
  }

  /// Gets the binary size in bytes
  static Future<int?> getBinarySize() async {
    final binaryPath = await getBinaryPath();
    final file = File(binaryPath);
    if (await file.exists()) {
      return await file.length();
    }
    return null;
  }

  /// Extracts openvpn.exe from the MSI installer
  ///
  /// Uses msiexec (native Windows) to extract files from the installer.
  /// Searches for openvpn.exe in the extracted files.
  ///
  /// Returns the path to the extracted openvpn.exe, or null if extraction fails.
  static Future<String?> _extractFromInstaller(String installerPath) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('MSI extraction is only supported on Windows');
    }

    final dir = await _getStorageDirectory();
    final extractDir = Directory(path.join(dir.path, 'extract_temp'));

    // Create temporary extraction directory
    if (await extractDir.exists()) {
      await extractDir.delete(recursive: true);
    }
    await extractDir.create(recursive: true);

    try {
      // Use msiexec to extract files
      // /a = administration mode (extraction)
      // /qb = silent user interface
      // TARGETDIR = destination directory
      final result = await Process.run(
        'msiexec',
        [
          '/a',
          installerPath,
          '/qb',
          'TARGETDIR=${extractDir.path}',
        ],
        runInShell: true,
      );

      if (result.exitCode != 0) {
        throw Exception('MSI extraction failed: ${result.stderr}');
      }

      // Search for openvpn.exe in extracted files
      // It's usually located in: extractDir/PFILES/OpenVPN/bin/openvpn.exe
      // or: extractDir/Program Files/OpenVPN/bin/openvpn.exe
      final possiblePaths = [
        path.join(extractDir.path, 'PFILES', 'OpenVPN', 'bin', binaryName),
        path.join(
            extractDir.path, 'Program Files', 'OpenVPN', 'bin', binaryName),
        path.join(extractDir.path, 'OpenVPN', 'bin', binaryName),
      ];

      // Search recursively if standard paths don't work
      String? foundPath;
      for (final possiblePath in possiblePaths) {
        final file = File(possiblePath);
        if (await file.exists()) {
          foundPath = possiblePath;
          break;
        }
      }

      // If not found, search recursively
      foundPath ??= await _findBinaryRecursive(extractDir, binaryName);

      return foundPath;
    } catch (e) {
      // Clean up on error
      if (await extractDir.exists()) {
        await extractDir.delete(recursive: true);
      }
      rethrow;
    }
  }

  /// Recursively searches for a file in a directory
  static Future<String?> _findBinaryRecursive(
      Directory dir, String fileName) async {
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File && path.basename(entity.path) == fileName) {
          return entity.path;
        }
      }
    } catch (e) {
      // Ignore permission errors
    }
    return null;
  }

  static Future<bool> _deployEmbeddedBinary({
    Function(double progress)? onProgress,
  }) async {
    final data = await _loadPluginAssetBytes('openvpn.exe.bin');

    if (data == null) {
      debugPrint(
          '❌ [OpenVPN] Aucun asset trouvé pour openvpn.exe.bin dans les chemins plugin.');
      return false;
    }

    // At this point, data is guaranteed to be non-null
    final loadedData = data;
    
    if (loadedData.lengthInBytes == 0) {
      throw Exception(
          'L’asset OpenVPN embarqué est vide. Remplace openvpn.exe.bin par un '
          'exécutable valide avant distribution.');
    }

    final binaryPath = await getBinaryPath();
    final tempPath = '$binaryPath.part';
    final tempFile = File(tempPath);

    await tempFile.writeAsBytes(
      loadedData.buffer.asUint8List(loadedData.offsetInBytes, loadedData.lengthInBytes),
    );

    await _verifyHash(tempFile);

    final targetFile = File(binaryPath);
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    await tempFile.rename(binaryPath);

    // Deploy runtime dependencies next to openvpn.exe.
    await _deployRuntimeDllsFromAssets(Directory(path.dirname(binaryPath)));
    await _deployInteractiveServiceBinaries(Directory(path.dirname(binaryPath)));

    await _saveInstalledVersion(targetVersion);
    await _persistHashFile();
    onProgress?.call(1.0);
    return true;
  }

  static Future<void> _ensureRuntimeDependenciesForExistingBinary(
      String binaryPath) async {
    final targetDir = Directory(path.dirname(binaryPath));
    final missing = await _missingRuntimeDlls(targetDir.path);
    if (missing.isNotEmpty) {
      debugPrint(
          '⚠️ [OpenVPN] DLL runtime manquantes détectées (${missing.join(", ")}), tentative de réparation via assets.');
      await _deployRuntimeDllsFromAssets(targetDir, failIfMissing: true);
    }

    // Toujours garantir la présence du service Interactive: les installations
    // antérieures à son introduction ont déjà openvpn.exe + DLL runtime, donc
    // le déploiement doit se faire même quand aucune DLL ne manque.
    await _deployInteractiveServiceBinaries(targetDir);
  }

  static Future<void> _deployInteractiveServiceBinaries(
    Directory targetDir, {
    bool failIfMissing = true,
  }) async {
    final servPath = path.join(
      targetDir.path,
      interactiveServiceBinaryName,
    );
    final servFile = File(servPath);

    // Redeploy when the binary is missing OR when the deployed file does not
    // match the expected hash for the current architecture/version. This
    // self-heals stale `openvpnserv.exe` left by a previous OpenVPN version:
    // the upgrade path refreshes `openvpn.exe` but a version mismatch between
    // openvpn.exe (new) and the Interactive Service (old) breaks the service
    // IPC (e.g. Register_dns), which tears the tunnel down after connect.
    var needsServDeploy = !await servFile.exists();
    if (!needsServDeploy && expectedInteractiveServiceHash != null) {
      final actual = await calculateFileHash(servFile);
      needsServDeploy =
          actual.toLowerCase() != expectedInteractiveServiceHash!.toLowerCase();
      if (needsServDeploy) {
        debugPrint(
          '♻️ [OpenVPN] $interactiveServiceBinaryName obsolète '
          '(hash différent), redéploiement de la version embarquée.',
        );
      }
    }

    if (needsServDeploy) {
      final data = await _loadPluginAssetBytes(
        '$interactiveServiceBinaryName.bin',
        allowBinSuffix: false,
      );
      if (data == null) {
        if (failIfMissing) {
          throw Exception(
            'Binaire Interactive Service manquant dans les assets: '
            '$interactiveServiceBinaryName.bin',
          );
        }
        return;
      }
      await _writeAssetToPath(data, servPath);
      if (expectedInteractiveServiceHash != null) {
        await _verifyHashWithExpected(
          File(servPath),
          expectedInteractiveServiceHash!,
        );
      }
      debugPrint('✅ [OpenVPN] Interactive Service déployé: $servPath');
    }

    // Keep the message DLL in sync: redeploy it whenever the service binary was
    // (re)deployed, or when it is missing.
    final msgPath = path.join(targetDir.path, interactiveServiceMsgDll);
    if (needsServDeploy || !await File(msgPath).exists()) {
      final msgData = await _loadPluginAssetBytes(
        '$interactiveServiceMsgDll.bin',
        allowBinSuffix: false,
      );
      if (msgData != null) {
        await _writeAssetToPath(msgData, msgPath);
        debugPrint('✅ [OpenVPN] DLL service déployée: $msgPath');
      }
    }
  }

  static Future<void> _writeAssetToPath(ByteData data, String targetPath) async {
    final tempFile = File('$targetPath.part');
    await tempFile.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final targetFile = File(targetPath);
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    await tempFile.rename(targetPath);
  }

  static Future<void> _verifyHashWithExpected(
    File file,
    String expected,
  ) async {
    final actualHash = await calculateFileHash(file);
    if (actualHash.toLowerCase() != expected.toLowerCase()) {
      await file.delete();
      throw Exception(
        'Hash mismatch for ${file.path}. Expected: $expected, got: $actualHash',
      );
    }
  }

  static Future<void> _deployRuntimeDllsFromAssets(
    Directory targetDir, {
    bool failIfMissing = true,
  }) async {
    final missing = <String>[];

    for (final dllName in requiredRuntimeDlls) {
      final data = await _loadPluginAssetBytes(dllName, allowBinSuffix: true);
      if (data == null) {
        missing.add(dllName);
        continue;
      }

      final targetPath = path.join(targetDir.path, dllName);
      final tempFile = File('$targetPath.part');
      await tempFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );

      final targetFile = File(targetPath);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await tempFile.rename(targetPath);
      debugPrint('✅ [OpenVPN] DLL déployée: $dllName');
    }

    if (missing.isNotEmpty && failIfMissing) {
      throw Exception(
        'DLL runtime OpenVPN manquantes dans les assets du plugin: ${missing.join(", ")}. '
        'Ajoute ces fichiers dans assets/openvpn/windows/.',
      );
    }
  }

  static Future<ByteData?> _loadPluginAssetBytes(
    String fileName, {
    bool allowBinSuffix = false,
  }) async {
    final candidates = <String>[];
    for (final basePath in _assetBasePaths) {
      candidates.add('$basePath/$fileName');
      if (allowBinSuffix && !fileName.endsWith('.bin')) {
        candidates.add('$basePath/$fileName.bin');
      }
    }

    for (final candidate in candidates) {
      try {
        final data = await rootBundle.load(candidate);
        debugPrint(
            '✅ [OpenVPN] Asset trouvé: $candidate (${data.lengthInBytes} bytes)');
        return data;
      } on FlutterError {
        // Try next candidate.
      } catch (e) {
        debugPrint('⚠️ [OpenVPN] Erreur chargement asset $candidate: $e');
      }
    }
    return null;
  }

  static Future<List<String>> _missingRuntimeDlls(String directoryPath) async {
    final missing = <String>[];
    for (final dllName in requiredRuntimeDlls) {
      final file = File(path.join(directoryPath, dllName));
      if (!await file.exists()) {
        missing.add(dllName);
      }
    }
    return missing;
  }

  static Future<void> _copyRuntimeDllsFromDirectory({
    required String sourceDirectoryPath,
    required String targetDirectoryPath,
    bool failIfMissing = true,
  }) async {
    final missing = <String>[];

    for (final dllName in requiredRuntimeDlls) {
      final sourcePath = await _findFileCaseInsensitive(
        sourceDirectoryPath,
        dllName,
      );
      if (sourcePath == null) {
        missing.add(dllName);
        continue;
      }

      final targetPath = path.join(targetDirectoryPath, dllName);
      await File(sourcePath).copy(targetPath);
      debugPrint('✅ [OpenVPN] DLL copiée depuis installeur: $dllName');
    }

    if (missing.isNotEmpty && failIfMissing) {
      throw Exception(
        'DLL runtime manquantes dans l’installeur OpenVPN: ${missing.join(", ")}',
      );
    }
  }

  static Future<String?> _findFileCaseInsensitive(
    String directoryPath,
    String fileName,
  ) async {
    final expected = fileName.toLowerCase();
    final direct = File(path.join(directoryPath, fileName));
    if (await direct.exists()) {
      return direct.path;
    }

    try {
      final dir = Directory(directoryPath);
      if (!await dir.exists()) {
        return null;
      }
      await for (final entity in dir.list()) {
        if (entity is File &&
            path.basename(entity.path).toLowerCase() == expected) {
          return entity.path;
        }
      }
    } catch (_) {
      // Ignore and report not found.
    }
    return null;
  }
}
