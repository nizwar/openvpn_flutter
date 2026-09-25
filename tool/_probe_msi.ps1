$paths = @(
    'C:\Program Files\OpenVPN',
    'C:\Program Files\OpenVPN\bin',
    'C:\ProgramData\LavControl\OpenVPN'
)
foreach ($p in $paths) {
    if (Test-Path $p) {
        Write-Output "=== $p ==="
        Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'tapinstall|ovpn-dco|tap-windows|tap0901|\.inf|\.sys|\.cat' } |
            Select-Object -ExpandProperty FullName
    }
}

$urls = @(
    'https://build.openvpn.net/downloads/releases/OpenVPN-2.7.5-I601-amd64.msi',
    'https://build.openvpn.net/downloads/releases/OpenVPN-2.7.5-I001-amd64.msi',
    'https://build.openvpn.net/downloads/releases/OpenVPN-2.7.5-I002-amd64.msi'
)
foreach ($u in $urls) {
    try {
        $r = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 15
        Write-Output "OK $u $($r.StatusCode)"
    } catch {
        Write-Output "FAIL $u"
    }
}
