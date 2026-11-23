# Run from an x64 Visual Studio developer shell. See tallowengine.com/docs/building-from-source.
$ErrorActionPreference = 'Stop'
& python (Join-Path $PSScriptRoot 'tools/build.py') @args
exit $LASTEXITCODE
