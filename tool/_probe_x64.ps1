$work = Join-Path $env:TEMP 'ovpn_probe_x64'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$msi = Join-Path $work 'OpenVPN.msi'
Invoke-WebRequest -Uri 'https://build.openvpn.net/downloads/releases/OpenVPN-2.7.5-I001-amd64.msi' -OutFile $msi -UseBasicParsing
$extract = Join-Path $work 'extract'
New-Item -ItemType Directory -Force -Path $extract | Out-Null
Start-Process msiexec.exe -ArgumentList @('/a', "`"$msi`"", '/qn', "TARGETDIR=`"$extract`"") -Wait
Get-ChildItem $extract -Recurse -File |
    Where-Object { $_.Name -match 'tapinstall|tapctl|ovpn|dco|tap-windows|tap0901|\.inf|\.sys|\.cat' } |
    ForEach-Object { $_.FullName.Replace($extract + '\', '') }
