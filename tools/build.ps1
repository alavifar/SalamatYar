param([string]$Dir = (Split-Path $PSScriptRoot -Parent))
# Builds SalamatYar.exe (the launcher) and dist\SalamatYar.zip (the download package).
# Uses the C# compiler that ships with Windows; nothing to install.
$ErrorActionPreference = 'Stop'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe (.NET Framework 4) was not found.' }

$exe = Join-Path $Dir 'SalamatYar.exe'
& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/win32icon:$Dir\SalamatYar.ico" "/out:$exe" /reference:System.Windows.Forms.dll "$Dir\launcher\Launcher.cs"
if ($LASTEXITCODE -ne 0) { throw 'Compiling the launcher failed.' }

$stage = Join-Path $env:TEMP ('salamatyar-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory (Join-Path $stage 'SalamatYar') | Out-Null
foreach ($f in 'SalamatYar.exe', 'SalamatYar.ps1', 'lang.json', 'SalamatYar.ico', 'Run.cmd', 'README.md', 'README.fa.md', 'LICENSE') {
    Copy-Item (Join-Path $Dir $f) (Join-Path $stage 'SalamatYar')
}
$dist = Join-Path $Dir 'dist'
if (-not (Test-Path $dist)) { New-Item -ItemType Directory $dist | Out-Null }
$zip = Join-Path $dist 'SalamatYar.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive (Join-Path $stage 'SalamatYar') $zip
Remove-Item $stage -Recurse -Force
"exe: {0} bytes" -f (Get-Item $exe).Length
"zip: {0} bytes" -f (Get-Item $zip).Length
