# Downloads official OpenVPN Windows MSIs (amd64 + arm64),
# extracts runtime binaries and tapctl, stages them as Flutter assets
# under assets/openvpn/windows/<x64|arm64>/.
#
# OpenVPN 2.7 uses tapctl.exe to install/create ovpn-dco and TAP adapters.
#
# Usage: powershell -ExecutionPolicy Bypass -File tool/fetch_openvpn_binaries.ps1 -Version 2.7.5
param(
    [string]$Version = "2.7.5",
    [string[]]$InstallerTokens = @("I001", "I002")
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
$assetsRoot = Join-Path $repoRoot "assets\openvpn\windows"
$work = Join-Path $env:TEMP ("ovpn_fetch_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null

$archMap = @{ "amd64" = "x64"; "arm64" = "arm64" }

function Download-First {
    param([string[]]$Urls, [string]$OutFile)
    foreach ($u in $Urls) {
        try {
            Invoke-WebRequest -Uri $u -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
            Write-Output "  downloaded: $u"
            return $true
        }
        catch {
            Write-Output "  miss: $u ($($_.Exception.Message))"
        }
    }
    return $false
}

function Find-One {
    param([string]$Root, [string]$Pattern)
    $hit = Get-ChildItem -Path $Root -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

foreach ($msiArch in $archMap.Keys) {
    $sub = $archMap[$msiArch]
    $destDir = Join-Path $assetsRoot $sub
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Write-Output "== OpenVPN $Version $msiArch -> $sub =="

    $urls = @()
    foreach ($tok in $InstallerTokens) {
        $urls += "https://build.openvpn.net/downloads/releases/OpenVPN-$Version-$tok-$msiArch.msi"
    }
    $msi = Join-Path $work "OpenVPN-$Version-$msiArch.msi"
    if (-not (Download-First -Urls $urls -OutFile $msi)) {
        throw "Unable to download OpenVPN MSI for $msiArch (version $Version)"
    }

    $extract = Join-Path $work "extract_$msiArch"
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    $log = Join-Path $work "msi_$msiArch.log"
    $p = Start-Process msiexec.exe -ArgumentList @("/a", "`"$msi`"", "/qn", "TARGETDIR=`"$extract`"", "/l*v", "`"$log`"") -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec extraction failed for $msiArch (exit $($p.ExitCode))" }

    $copies = @(
        @{ pat = "openvpn.exe";            dest = "openvpn.exe.bin" },
        @{ pat = "openvpnserv.exe";        dest = "openvpnserv.exe.bin" },
        @{ pat = "openvpnservmsg.dll";     dest = "openvpnservmsg.dll.bin" },
        @{ pat = "tapctl.exe";             dest = "tapctl.exe.bin" },
        @{ pat = "libpkcs11-helper-1.dll"; dest = "libpkcs11-helper-1.dll" },
        @{ pat = "libcrypto-3-*.dll";      dest = $null },
        @{ pat = "libssl-3-*.dll";         dest = $null }
    )

    foreach ($c in $copies) {
        $src = Find-One -Root $extract -Pattern $c.pat
        if (-not $src) { throw "Missing '$($c.pat)' in extracted $msiArch MSI" }
        $destName = $c.dest
        if (-not $destName) { $destName = Split-Path $src -Leaf }
        Copy-Item -Path $src -Destination (Join-Path $destDir $destName) -Force
        Write-Output "  copied: $(Split-Path $src -Leaf) -> $destName"
    }

    # Kernel drivers are not included in the admin MSI extract; bundle signed
    # packages for pnputil during LavControl elevated setup.
    $driversRoot = Join-Path $destDir "drivers"
    New-Item -ItemType Directory -Force -Path $driversRoot | Out-Null

    $dcoZipName = if ($msiArch -eq "arm64") { "ovpn-dco-win-2.8.3-arm64.zip" } else { "ovpn-dco-win-2.8.3-amd64.zip" }
    $dcoZip = Join-Path $work $dcoZipName
    if (-not (Download-First -Urls @(
            "https://github.com/OpenVPN/ovpn-dco-win/releases/download/2.8.3/$dcoZipName"
        ) -OutFile $dcoZip)) {
        throw "Unable to download ovpn-dco driver package for $msiArch"
    }
    $dcoExtract = Join-Path $work "dco_$msiArch"
    New-Item -ItemType Directory -Force -Path $dcoExtract | Out-Null
    Expand-Archive -Path $dcoZip -DestinationPath $dcoExtract -Force
    foreach ($flavor in @("win10", "win11")) {
        $srcFlavor = Join-Path $dcoExtract $flavor
        if (-not (Test-Path $srcFlavor)) { continue }
        $dstFlavor = Join-Path $driversRoot "ovpn-dco\$flavor"
        New-Item -ItemType Directory -Force -Path $dstFlavor | Out-Null
        Copy-Item -Path (Join-Path $srcFlavor "*") -Destination $dstFlavor -Force
        Write-Output "  copied: ovpn-dco/$flavor"
    }

    $tapZip = Join-Path $work "dist.win10.zip"
    if (-not (Download-First -Urls @(
            "https://github.com/OpenVPN/tap-windows6/releases/download/9.27.0/dist.win10.zip"
        ) -OutFile $tapZip)) {
        throw "Unable to download tap-windows6 driver package"
    }
    $tapExtract = Join-Path $work "tap_$msiArch"
    New-Item -ItemType Directory -Force -Path $tapExtract | Out-Null
    Expand-Archive -Path $tapZip -DestinationPath $tapExtract -Force
    $tapPlatform = if ($msiArch -eq "arm64") { "arm64" } else { "amd64" }
    # The zip nests everything under a top-level dist.win10/ folder; locate the
    # per-platform directory by its INF rather than assuming the layout.
    $tapInf = Get-ChildItem -Path $tapExtract -Recurse -File -Filter "OemVista.inf" -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq $tapPlatform } |
        Select-Object -First 1
    if (-not $tapInf) { throw "TAP driver folder missing for $tapPlatform in dist.win10.zip" }
    $tapSrc = $tapInf.Directory.FullName
    $tapDst = Join-Path $driversRoot "tap\$tapPlatform\win10"
    New-Item -ItemType Directory -Force -Path $tapDst | Out-Null
    # Only the driver package itself; devcon.exe is not needed (tapctl handles adapters).
    foreach ($name in @("OemVista.inf", "tap0901.cat", "tap0901.sys")) {
        Copy-Item -Path (Join-Path $tapSrc $name) -Destination $tapDst -Force
    }
    Write-Output "  copied: tap/$tapPlatform/win10"
}

Write-Output ""
Write-Output "===== SHA256 (fill into WindowsBinaryManager) ====="
foreach ($msiArch in $archMap.Keys) {
    $sub = $archMap[$msiArch]
    $destDir = Join-Path $assetsRoot $sub
    Write-Output "--- $sub ---"
    Get-ChildItem -Path $destDir -File | ForEach-Object {
        $h = (Get-FileHash -Algorithm SHA256 -Path $_.FullName).Hash
        Write-Output ("  {0}  {1}  ({2} bytes)" -f $_.Name, $h, $_.Length)
    }
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Output "DONE"
