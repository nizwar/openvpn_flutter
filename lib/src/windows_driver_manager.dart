import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as path;

import 'windows_binary_manager.dart';

/// Deploys [tapctl.exe] and creates ovpn-dco / TAP adapters on Windows.
///
/// OpenVPN 2.7 uses `tapctl create --hwid ovpn-dco` (default) for Win-DCO and
/// `tapctl create --hwid tap0901` for TAP fallback adapters.
class WindowsDriverManager {
  static const String tapCtlAssetName = 'tapctl.exe.bin';
  static const String tapCtlBinaryName = 'tapctl.exe';

  static List<String> get _assetBasePaths => [
        'packages/openvpn_flutter/assets/openvpn/windows/${WindowsBinaryManager.windowsArch}',
        'assets/openvpn/windows/${WindowsBinaryManager.windowsArch}',
      ];

  static Future<String> getMachineDirectory() async {
    return WindowsBinaryManager.getMachineRuntimeDirectory();
  }

  static Future<String> getStagingDirectory() async {
    final staging = await WindowsBinaryManager.getRuntimeDirectory();
    return staging.path;
  }

  static Future<String> getMachineTapCtlPath() async {
    final machineDir = await getMachineDirectory();
    return path.join(machineDir, tapCtlBinaryName);
  }

  static Future<String> getStagingTapCtlPath() async {
    final stagingDir = await getStagingDirectory();
    return path.join(stagingDir, tapCtlBinaryName);
  }

  static Future<bool> isDcoAdapterPresent() async {
    return _runPowerShellBool(
      "Get-NetAdapter -ErrorAction SilentlyContinue | "
      "Where-Object { \$_.InterfaceDescription -match "
      "'OpenVPN Data Channel|ovpn-dco|Data Channel Offload' } | "
      "Select-Object -First 1 | ForEach-Object { \$true }",
    );
  }

  static Future<bool> isTapAdapterPresent() async {
    return _runPowerShellBool(
      "Get-NetAdapter -ErrorAction SilentlyContinue | "
      "Where-Object { \$_.InterfaceDescription -match 'TAP-Windows|TAP-Windows6' } | "
      "Select-Object -First 1 | ForEach-Object { \$true }",
    );
  }

  static Future<bool> _runPowerShellBool(String script) async {
    if (!Platform.isWindows) return false;
    try {
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
        runInShell: true,
      );
      return (result.stdout as String).trim().toLowerCase().contains('true');
    } catch (_) {
      return false;
    }
  }

  /// Copies bundled tapctl.exe and driver packages to the staging directory.
  ///
  /// Returns `false` when tapctl or every driver package is missing from the
  /// bundle: the elevated setup would then be unable to create any adapter on
  /// a machine without OpenVPN preinstalled.
  static Future<bool> ensureDriversDeployed({
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isWindows) return true;
    onProgress?.call(0.1);

    final data = await _loadTapCtlAsset();
    if (data == null || data.lengthInBytes == 0) {
      debugPrint('⚠️ [OpenVPN] tapctl.exe asset missing in bundle');
      onProgress?.call(1.0);
      return false;
    }

    final stagingDir = await getStagingDirectory();
    final dest = path.join(stagingDir, tapCtlBinaryName);
    await File(dest).writeAsBytes(data.buffer.asUint8List(), flush: true);
    debugPrint('✅ [OpenVPN] tapctl deployed: $dest');

    onProgress?.call(0.5);
    final copied = await _deployBundledDriverAssets(stagingDir);
    onProgress?.call(1.0);
    return copied > 0;
  }

  /// Returns the number of driver files written to [stagingDir].
  static Future<int> _deployBundledDriverAssets(String stagingDir) async {
    final arch = WindowsBinaryManager.windowsArch;
    final platform = arch == 'arm64' ? 'arm64' : 'amd64';
    final driverFiles = <String>[
      'drivers/ovpn-dco/win10/ovpn-dco.inf',
      'drivers/ovpn-dco/win10/ovpn-dco.cat',
      'drivers/ovpn-dco/win10/ovpn-dco.sys',
      'drivers/ovpn-dco/win11/ovpn-dco.inf',
      'drivers/ovpn-dco/win11/ovpn-dco.cat',
      'drivers/ovpn-dco/win11/ovpn-dco.sys',
      'drivers/tap/$platform/win10/OemVista.inf',
      'drivers/tap/$platform/win10/tap0901.cat',
      'drivers/tap/$platform/win10/tap0901.sys',
    ];

    var copied = 0;
    for (final relative in driverFiles) {
      final bytes = await _loadDriverAsset(relative);
      if (bytes == null) continue;
      final out = path.join(stagingDir, relative);
      await Directory(path.dirname(out)).create(recursive: true);
      await File(out).writeAsBytes(bytes, flush: true);
      copied++;
    }
    if (copied > 0) {
      debugPrint('✅ [OpenVPN] $copied driver file(s) deployed under $stagingDir/drivers');
    } else {
      debugPrint(
        '⚠️ [OpenVPN] No bundled driver packages in app assets; '
        'run tool/fetch_openvpn_binaries.ps1 before building',
      );
    }
    return copied;
  }

  static Future<List<int>?> _loadDriverAsset(String relativePath) async {
    for (final base in _assetBasePaths) {
      final candidate = '$base/$relativePath';
      try {
        final data = await rootBundle.load(candidate);
        return data.buffer.asUint8List().toList();
      } catch (_) {}
    }
    return null;
  }

  static Future<ByteData?> _loadTapCtlAsset() async {
    for (final base in _assetBasePaths) {
      final candidate = '$base/$tapCtlAssetName';
      try {
        return await rootBundle.load(candidate);
      } catch (_) {}
    }
    return null;
  }

  /// PowerShell fragment for elevated adapter/driver setup via tapctl.
  ///
  /// Installs ovpn-dco first on every OS (win10/win11 flavor by build). TAP
  /// packages stay in the bundle for fallback only: the tap0901 adapter is
  /// created when `tapctl list` shows no ovpn-dco adapter after DCO setup.
  /// Writes [WindowsBinaryManager.preferredDriverFileName] and throws when
  /// neither adapter is present.
  ///
  /// This fragment is inlined into the host's elevated script, which provides
  /// `Log-Step`. Function names defined here must not collide with the host's
  /// (e.g. `Invoke-NativeLogged`): a redefinition silently replaces the host
  /// function for the rest of the script and breaks service start.
  static String installDriversScriptBody({
    required String stagingDir,
    required String machineDir,
  }) {
    final staging = stagingDir.replaceAll("'", "''");
    final machine = machineDir.replaceAll("'", "''");
    final bundleArch = WindowsBinaryManager.windowsArch;
    final processMachine =
        WindowsBinaryManager.processMachine?.toRadixString(16) ?? 'unknown';
    final nativeMachine =
        WindowsBinaryManager.nativeMachine?.toRadixString(16) ?? 'unknown';
    final expectedPe =
        WindowsBinaryManager.expectedDriverPeMachine.toRadixString(16);
    final markerName = WindowsBinaryManager.preferredDriverFileName;
    return '''
function Invoke-DriverToolLogged {
  param(
    [string]\$Label,
    [string]\$FilePath,
    [string[]]\$ArgumentList
  )
  \$prev = \$ErrorActionPreference
  \$ErrorActionPreference = 'Continue'
  try {
    \$output = & \$FilePath @ArgumentList 2>&1 | Out-String
    \$exit = \$LASTEXITCODE
    if ([string]::IsNullOrWhiteSpace(\$output)) { \$output = '(no output)' }
    Log-Step "[LAVCONTROL] \$Label exit=\$exit output:`n\$output"
    return \$output
  } catch {
    Log-Step "[LAVCONTROL] \$Label threw: \$(\$_.Exception.Message)"
    return ''
  } finally {
    \$ErrorActionPreference = \$prev
  }
}

function Get-OvpnDcoOsFlavor {
  try {
    \$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    if (\$build -ge 22000) { return 'win11' }
  } catch {}
  return 'win10'
}

function Get-PeMachine {
  param([string]\$SysPath)
  try {
    \$bytes = [System.IO.File]::ReadAllBytes(\$SysPath)
    if (\$bytes.Length -lt 0x40) { return 0 }
    \$peOffset = [BitConverter]::ToInt32(\$bytes, 0x3C)
    if ((\$peOffset + 6) -gt \$bytes.Length) { return 0 }
    if (\$bytes[\$peOffset] -ne 0x50 -or \$bytes[\$peOffset + 1] -ne 0x45) { return 0 }
    return [int][BitConverter]::ToUInt16(\$bytes, \$peOffset + 4)
  } catch {
    return 0
  }
}

function Assert-SysMatchesKernel {
  param(
    [string]\$Label,
    [string]\$InfPath,
    [int]\$ExpectedPe
  )
  \$sysName = if (\$Label -eq 'ovpn-dco') { 'ovpn-dco.sys' } else { 'tap0901.sys' }
  \$sysPath = Join-Path (Split-Path -Parent \$InfPath) \$sysName
  if (-not (Test-Path -LiteralPath \$sysPath)) {
    throw "[LAVCONTROL] \$Label .sys missing next to INF: \$sysPath"
  }
  \$pe = Get-PeMachine -SysPath \$sysPath
  Log-Step ("[LAVCONTROL] Arch check process=0x$processMachine native=0x$nativeMachine bundle=$bundleArch pe=0x{0:X} expected=0x$expectedPe sys=\$sysPath" -f \$pe)
  if (\$pe -ne \$ExpectedPe) {
    throw ("[LAVCONTROL] Refusing \$Label .sys PE machine 0x{0:X} (kernel expects 0x$expectedPe)" -f \$pe)
  }
}

function Install-DriverPackageIfPresent {
  param(
    [string]\$Label,
    [string]\$InfPath,
    [int]\$ExpectedPe
  )
  if (-not (Test-Path -LiteralPath \$InfPath)) {
    Log-Step "[LAVCONTROL] \$Label driver package missing: \$InfPath"
    return \$false
  }
  Assert-SysMatchesKernel -Label \$Label -InfPath \$InfPath -ExpectedPe \$ExpectedPe
  Log-Step "[LAVCONTROL] Installing \$Label driver via pnputil: \$InfPath"
  Invoke-DriverToolLogged -Label "pnputil \$Label" -FilePath 'pnputil.exe' -ArgumentList @('/add-driver', \$InfPath, '/install') | Out-Null
  return \$true
}

function Invoke-TapCtlCreateWithRetry {
  param(
    [string]\$TapCtl,
    [string]\$Label,
    [string[]]\$ArgumentList,
    [int]\$MaxAttempts = 6,
    [int]\$DelaySeconds = 2
  )
  for (\$attempt = 1; \$attempt -le \$MaxAttempts; \$attempt++) {
    \$output = Invoke-DriverToolLogged -Label "\$Label attempt \$attempt/\$MaxAttempts" -FilePath \$TapCtl -ArgumentList \$ArgumentList
    if (\$output -match '\\{[0-9a-fA-F-]{36}\\}') {
      Log-Step "[LAVCONTROL] \$Label succeeded on attempt \$attempt"
      return \$true
    }
    if (\$output -notmatch 'SetupDiOpenDevRegKey failed|DinstallDevice failed|failed|error') {
      Log-Step "[LAVCONTROL] \$Label finished without GUID but no fatal pattern; stopping retries"
      return \$false
    }
    if (\$attempt -lt \$MaxAttempts) {
      Log-Step "[LAVCONTROL] \$Label retry in \$DelaySeconds s (SetupDiOpenDevRegKey / driver store not ready yet)"
      Start-Sleep -Seconds \$DelaySeconds
    }
  }
  Log-Step "[LAVCONTROL] \$Label failed after \$MaxAttempts attempt(s)"
  return \$false
}

function Find-DriverInf {
  param(
    [string]\$StagingDir,
    [string]\$MachineDir,
    [string]\$Relative,
    [string]\$Fallback = \$null
  )
  foreach (\$root in @(
    (Join-Path \$StagingDir 'drivers'),
    (Join-Path \$MachineDir 'drivers')
  )) {
    if (-not (Test-Path \$root)) { continue }
    \$inf = Join-Path \$root \$Relative
    if (Test-Path -LiteralPath \$inf) { return \$inf }
    if (\$Fallback) {
      \$alt = Join-Path \$root \$Fallback
      if (Test-Path -LiteralPath \$alt) { return \$alt }
    }
  }
  return \$null
}

function Test-TapCtlAdapterPresent {
  param(
    [string]\$ListOutput,
    [string]\$Pattern
  )
  return [bool](\$ListOutput -match \$Pattern)
}

function Write-PreferredDriverMarker {
  param(
    [string]\$MachineDir,
    [string]\$Driver
  )
  \$marker = Join-Path \$MachineDir '$markerName'
  Set-Content -LiteralPath \$marker -Value \$Driver -Encoding ascii -NoNewline
  Log-Step "[LAVCONTROL] Wrote preferred driver marker: \$marker = \$Driver"
}

function Install-OpenVpnDrivers {
  param(
    [string]\$StagingDir,
    [string]\$MachineDir
  )
  \$arch = '$bundleArch'
  \$platform = if (\$arch -eq 'arm64') { 'arm64' } else { 'amd64' }
  \$expectedPe = [int]"0x$expectedPe"
  \$dcoFlavor = Get-OvpnDcoOsFlavor

  Log-Step "[LAVCONTROL] Arch process=0x$processMachine native=0x$nativeMachine bundle=$bundleArch expectedPe=0x$expectedPe dcoFlavor=\$dcoFlavor"

  \$driversStaging = Join-Path \$StagingDir 'drivers'
  \$driversMachine = Join-Path \$MachineDir 'drivers'
  if (Test-Path \$driversStaging) {
    New-Item -ItemType Directory -Force -Path \$driversMachine | Out-Null
    Copy-Item -Path (Join-Path \$driversStaging '*') -Destination \$driversMachine -Recurse -Force -ErrorAction SilentlyContinue
    Log-Step "[LAVCONTROL] Driver packages copied to \$driversMachine"
  }

  \$tapctlStaging = Join-Path \$StagingDir 'tapctl.exe'
  if (-not (Test-Path \$tapctlStaging)) {
    \$tapctlBin = Join-Path \$StagingDir 'tapctl.exe.bin'
    if (Test-Path \$tapctlBin) {
      Copy-Item -Path \$tapctlBin -Destination \$tapctlStaging -Force
    }
  }
  \$tapctl = Join-Path \$MachineDir 'tapctl.exe'
  if (Test-Path \$tapctlStaging) {
    Copy-Item -Path \$tapctlStaging -Destination \$tapctl -Force
    Log-Step "[LAVCONTROL] tapctl.exe deployed to \$tapctl"
  } elseif (-not (Test-Path \$tapctl)) {
    throw "[LAVCONTROL] tapctl.exe missing; cannot create VPN adapters"
  }

  \$list = Invoke-DriverToolLogged -Label 'tapctl list (before)' -FilePath \$tapctl -ArgumentList @('list')
  Log-Step "[LAVCONTROL] tapctl list before install:`n\$list"

  # --- DCO first (every OS / arch) ---
  \$dcoInf = Find-DriverInf -StagingDir \$StagingDir -MachineDir \$MachineDir `
    -Relative ("ovpn-dco/" + \$dcoFlavor + "/ovpn-dco.inf")
  if (\$dcoInf) {
    Install-DriverPackageIfPresent -Label 'ovpn-dco' -InfPath \$dcoInf -ExpectedPe \$expectedPe | Out-Null
    Start-Sleep -Seconds 3
  } else {
    Log-Step "[LAVCONTROL] ovpn-dco INF not found for flavor \$dcoFlavor"
  }

  if (-not (Test-TapCtlAdapterPresent -ListOutput \$list -Pattern 'ovpn-dco|Data Channel Offload')) {
    Log-Step "[LAVCONTROL] Creating ovpn-dco adapter (Win-DCO)"
    \$dcoRetry = @{ TapCtl = \$tapctl; Label = 'tapctl create ovpn-dco'; ArgumentList = @(
      'create', '--hwid', 'ovpn-dco', '--name', 'OpenVPN Data Channel Offload'
    ) }
    if (\$arch -eq 'arm64') {
      \$dcoRetry.MaxAttempts = 8
      \$dcoRetry.DelaySeconds = 3
    }
    Invoke-TapCtlCreateWithRetry @dcoRetry | Out-Null
  }

  \$list = Invoke-DriverToolLogged -Label 'tapctl list (after DCO)' -FilePath \$tapctl -ArgumentList @('list')
  if (Test-TapCtlAdapterPresent -ListOutput \$list -Pattern 'ovpn-dco|Data Channel Offload') {
    Write-PreferredDriverMarker -MachineDir \$MachineDir -Driver 'ovpn-dco'
    Log-Step "[LAVCONTROL] ovpn-dco adapter present; skipping TAP creation"
    return
  }

  # --- TAP fallback only when DCO adapter is absent ---
  Log-Step "[LAVCONTROL] ovpn-dco adapter absent; installing tap-windows6 fallback"
  \$tapInf = Find-DriverInf -StagingDir \$StagingDir -MachineDir \$MachineDir `
    -Relative ("tap/" + \$platform + "/win10/OemVista.inf") `
    -Fallback ("tap/" + \$platform + "/OemVista.inf")
  if (\$tapInf) {
    Install-DriverPackageIfPresent -Label 'tap-windows6' -InfPath \$tapInf -ExpectedPe \$expectedPe | Out-Null
    Start-Sleep -Seconds 3
  } else {
    Log-Step "[LAVCONTROL] tap-windows6 INF not found for platform \$platform"
  }

  if (-not (Test-TapCtlAdapterPresent -ListOutput \$list -Pattern 'tap0901|TAP-Windows6')) {
    Log-Step "[LAVCONTROL] Creating tap-windows6 adapter (fallback)"
    \$tapRetry = @{ TapCtl = \$tapctl; Label = 'tapctl create tap0901'; ArgumentList = @(
      'create', '--hwid', 'tap0901', '--name', 'OpenVPN TAP-Windows6'
    ) }
    if (\$arch -eq 'arm64') {
      \$tapRetry.MaxAttempts = 8
      \$tapRetry.DelaySeconds = 3
    }
    Invoke-TapCtlCreateWithRetry @tapRetry | Out-Null
  }

  \$list = Invoke-DriverToolLogged -Label 'tapctl list (after TAP)' -FilePath \$tapctl -ArgumentList @('list')
  if (Test-TapCtlAdapterPresent -ListOutput \$list -Pattern 'tap0901|TAP-Windows6') {
    Write-PreferredDriverMarker -MachineDir \$MachineDir -Driver 'tap-windows6'
    return
  }

  throw "[LAVCONTROL] No VPN adapter available after DCO and TAP setup. tapctl list:`n\$list"
}

Install-OpenVpnDrivers -StagingDir '$staging' -MachineDir '$machine'
''';
  }
}
