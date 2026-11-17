# Build the transparent, user-controlled Session Watch from reviewable C# source.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'SessionWatch.cs'
$folder = Join-Path $env:LOCALAPPDATA 'SessionWatch'
$binary = Join-Path $folder 'SessionWatch.exe'
$compilers = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$compiler = $compilers | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) { throw 'C# compiler for .NET Framework not found. Install .NET Framework Developer Pack or Visual Studio C# build tools.' }
if (-not (Test-Path -LiteralPath $source)) { throw 'SessionWatch.cs not found.' }
New-Item -ItemType Directory -Path $folder -Force | Out-Null
& $compiler /nologo /target:winexe /optimize+ /platform:anycpu "/out:$binary" /reference:System.Management.dll "$source"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $binary)) { throw "Compilation failed ($LASTEXITCODE)." }
Write-Host '[+] Session Watch compiled locally.' -ForegroundColor Green
Write-Host "[+] EXE: $binary"
Write-Host "[+] SHA256: $((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash)"
Write-Host '[*] It has no tray icon, no startup task, and stays visible in Task Manager.'
