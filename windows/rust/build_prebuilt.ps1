# Rebuilds openvpn_flutter_rust.dll and copies it into prebuilt/ for distribution.
# Run on Windows (PowerShell) from the openvpn_flutter repo root or this folder.
#
# Prerequisites:
#   - Rust: https://rustup.rs/
#   - MSVC build tools (Visual Studio Build Tools with "Desktop development with C++")
#
# Usage:
#   pwsh -File windows/rust/build_prebuilt.ps1
#   pwsh -File windows/rust/build_prebuilt.ps1 -Profile debug

param(
    [ValidateSet("release", "debug")]
    [string]$Profile = "release"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rustDir = $scriptDir
$target = "x86_64-pc-windows-msvc"
# Always build into the repo target/ tree (avoid stale sandbox CARGO_TARGET_DIR).
$env:CARGO_TARGET_DIR = Join-Path $rustDir "target"
$cargoArgs = @("build", "--manifest-path", "$rustDir/Cargo.toml", "--target", $target)

if ($Profile -eq "release") {
    $cargoArgs += "--release"
    $cargoProfileDir = "release"
} else {
    $cargoProfileDir = "debug"
}

Write-Host "==> Building Rust ($Profile) for $target"
& cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$builtDir = Join-Path $rustDir "target/$target/$cargoProfileDir"
$prebuiltDir = Join-Path $rustDir "prebuilt/$target/$cargoProfileDir"
New-Item -ItemType Directory -Force -Path $prebuiltDir | Out-Null

$dllSrc = Join-Path $builtDir "openvpn_flutter_rust.dll"
$dllDst = Join-Path $prebuiltDir "openvpn_flutter_rust.dll"
Copy-Item $dllSrc $dllDst -Force
Write-Host "==> Copied $dllDst"

$importLibDllLib = Join-Path $builtDir "openvpn_flutter_rust.dll.lib"
$importLibLib = Join-Path $builtDir "openvpn_flutter_rust.lib"
if (Test-Path $importLibDllLib) {
    Copy-Item $importLibDllLib (Join-Path $prebuiltDir "openvpn_flutter_rust.dll.lib") -Force
    Write-Host "==> Copied openvpn_flutter_rust.dll.lib"
} elseif (Test-Path $importLibLib) {
    Copy-Item $importLibLib (Join-Path $prebuiltDir "openvpn_flutter_rust.lib") -Force
    Write-Host "==> Copied openvpn_flutter_rust.lib"
} else {
    throw "Import library not found in $builtDir"
}

Write-Host ""
Write-Host "OK - prebuilt artifacts updated in:"
Write-Host "  $prebuiltDir"
