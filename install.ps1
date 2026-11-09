# Installs the latest CleanBro for Windows from GitHub Releases.
#   irm https://raw.githubusercontent.com/jetorbitdev/cleanbro/main/install.ps1 | iex
# Files downloaded with Invoke-WebRequest don't carry the "Mark of the Web",
# so SmartScreen does not prompt. The installer runs per-user (no admin needed).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = 'jetorbitdev/cleanbro'
$base = "https://github.com/$repo/releases/latest/download"
$name = 'CleanBro-windows-setup.exe'
$tmp  = Join-Path ([IO.Path]::GetTempPath()) ("cleanbro-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    Write-Host 'Downloading CleanBro...'
    $exe = Join-Path $tmp $name
    Invoke-WebRequest -Uri "$base/$name" -OutFile $exe
    $sumFile = Join-Path $tmp "$name.sha256"
    Invoke-WebRequest -Uri "$base/$name.sha256" -OutFile $sumFile

    Write-Host 'Verifying checksum...'
    $expected = ((Get-Content $sumFile -Raw).Trim() -split '\s+')[0].ToLower()
    $actual = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { throw 'Checksum mismatch, aborting.' }

    Write-Host 'Installing...'
    Start-Process -FilePath $exe -ArgumentList '/S' -Wait
    Write-Host 'CleanBro installed. Find it in the Start menu.'
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
