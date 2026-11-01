# Shared Tallow Windows development-tool installer.
# This is the single source for the standalone launcher and packaged Tallow Manager.
# Both launch it off the UI thread and install into the same user-level toolchain folder.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'Tallow\toolchain'
$release = 'https://github.com/LazyAlgorithm/Tallow/releases/download/v0.1.0-beta'
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Install-Archive([string]$asset, [string]$marker, [string]$extraMarker = '') {
    if ((Test-Path (Join-Path $root $marker)) -and
        (-not $extraMarker -or (Test-Path (Join-Path $root $extraMarker)))) { return }
    $archive = Join-Path $env:TEMP $asset
    try {
        Write-Host "Downloading $asset"
        Invoke-WebRequest -Uri "$release/$asset" -OutFile $archive -TimeoutSec 180
        if ((Get-Item $archive).Length -lt 1000) { throw "Downloaded archive is unexpectedly small." }
        Write-Host "Extracting $asset"
        Expand-Archive -LiteralPath $archive -DestinationPath $root -Force
        if (-not (Test-Path (Join-Path $root $marker))) { throw "$asset did not contain $marker" }
        if ($extraMarker -and -not (Test-Path (Join-Path $root $extraMarker))) { throw "$asset did not contain $extraMarker" }
    } finally {
        Remove-Item $archive -Force -ErrorAction SilentlyContinue
    }
}

Install-Archive 'beef-windows-x64.zip' 'beef\bin\BeefBuild.exe' 'beef\BeefLibs\corlib\BeefProj.toml'
$corlib = Join-Path $root 'beef\BeefLibs\corlib\BeefProj.toml'
if (-not (Test-Path -LiteralPath $corlib)) { throw 'Beef standard library (corlib) is missing. The published toolchain archive is incomplete.' }
$config = Join-Path $root 'beef\bin\BeefConfig.toml'
Set-Content -LiteralPath $config -Value "Version = 1`nUnversionedLibDirs = [`"../BeefLibs`"]`n" -Encoding ASCII
# Use our managed Python directly. Do not invoke WindowsApps' Python Store alias:
# it is not a working interpreter and can stall unattended setup.
Install-Archive 'python-windows-x64.zip' 'python\python.exe'
# The embeddable Python distribution needs its stdlib zip, included in the official archive.
$python = Join-Path $root 'python\python.exe'
if (Test-Path $python) {
    & $python -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)'
    if ($LASTEXITCODE -ne 0) { throw 'Installed Python is not usable.' }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = ''
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vsPath) {
    $installer = Join-Path $env:TEMP 'vs_BuildTools.exe'
    try {
        Write-Host 'Installing Microsoft C++ Build Tools and Windows SDK (administrator approval required)'
        Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $installer
        $process = Start-Process -FilePath $installer -ArgumentList '--passive --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended' -Verb RunAs -Wait -PassThru
        if ($process.ExitCode -notin @(0,3010)) { throw "Build Tools installer exited with code $($process.ExitCode)." }
    } finally {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
}
if (-not $vsPath) { throw 'Microsoft C++ Build Tools are not installed or could not be detected.' }

$crt = Get-ChildItem (Join-Path $vsPath 'VC\Tools\MSVC') -Directory |
    Sort-Object Name -Descending |
    Where-Object { Test-Path (Join-Path $_.FullName 'lib\x64\libcmt.lib') } |
    Select-Object -First 1
$sdkBase = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
$sdk = Get-ChildItem $sdkBase -Directory |
    Sort-Object Name -Descending |
    Where-Object {
        (Test-Path (Join-Path $_.FullName 'um\x64\kernel32.lib')) -and
        (Test-Path (Join-Path $_.FullName 'ucrt\x64\ucrt.lib'))
    } | Select-Object -First 1
if (-not $crt -or -not $sdk) { throw 'C++ runtime or Windows SDK libraries could not be found.' }

$beefSettings = Join-Path $root 'beef\bin\BeefSettings.toml'
$crtPath = (Join-Path $crt.FullName 'lib\x64').Replace('\','/')
$umPath = (Join-Path $sdk.FullName 'um\x64').Replace('\','/')
$ucrtPath = (Join-Path $sdk.FullName 'ucrt\x64').Replace('\','/')
$settingsContent = @"
[VisualStudio]
ManuallySet = true
Bin32Path = ""
Bin64Path = ""
Lib32Paths = []
Lib64Paths = ["$crtPath", "$umPath", "$ucrtPath"]
"@
Set-Content -LiteralPath $beefSettings -Value $settingsContent -Encoding UTF8
if (-not (Test-Path (Join-Path $root 'beef\bin\BeefBuild.exe'))) { throw 'Beef compiler is missing.' }
Write-Host 'Tallow development dependencies are ready.'
