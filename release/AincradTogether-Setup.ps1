# ============================================================================
# AincradTogether one-file setup (Windows)
#
# Download this file ONCE. Every time you run it, it checks GitHub for the
# newest AincradTogether version, downloads it, and walks you through the
# whole install - game detection, the UE4SS mod loader, host/guest setup.
# Nothing else to download, no options to remember.
#
# Run it from PowerShell (Start menu -> type "powershell"):
#
#     powershell -ExecutionPolicy Bypass -File AincradTogether-Setup.ps1
#
# (Or right-click the file -> "Run with PowerShell".)
# ============================================================================

$ErrorActionPreference = 'Stop'
$repo = 'TheRealRyukiro/EchoesOfAincradMultiplayer'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ 'User-Agent' = 'AincradTogether-setup' }

Write-Host "==> Checking the latest AincradTogether version..." -ForegroundColor Cyan
$tag = $null
try {
    $tag = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers).tag_name
} catch { }

if ($tag) {
    $url = "https://github.com/$repo/archive/refs/tags/$tag.zip"
    Write-Host "    Latest release: $tag"
} else {
    $url = "https://github.com/$repo/archive/refs/heads/main.zip"
    Write-Host "    No tagged release found - using the latest development version."
}

$tmp = Join-Path $env:TEMP ("aincrad_setup_" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $zip = Join-Path $tmp 'repo.zip'
    Write-Host "==> Downloading..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $zip -Headers $headers
    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    $installer = Get-ChildItem -Path $tmp -Recurse -Filter 'install.ps1' |
        Where-Object { $_.FullName -like '*\tools\*' } |
        Select-Object -First 1
    if (-not $installer) { throw "Download looks broken (no tools\install.ps1 inside)" }

    Write-Host "==> Starting the guided installer..." -ForegroundColor Cyan
    Write-Host ""
    & $installer.FullName
} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
