# Builds dist\CommsuiteSetup.exe, replacing the old NSIS script:
#   1. stages dist\app (everything except *.WebView2 browser state) into a zip
#   2. builds the small standalone uninstaller (Role=Uninstall)
#   3. builds the setup exe with the payload zip + uninstaller embedded (Role=Setup)
#   4. copies the result to dist\CommsuiteSetup.exe
#
# Usage:  powershell -ExecutionPolicy Bypass -File installer\build.ps1
# Requires: .NET SDK (dotnet), a Flutter Windows build in dist\app.
param(
  [string]$Configuration = "Release",
  [string]$AppDir = "",   # defaults to <repo>\dist\app
  # -NoElevate builds with an asInvoker manifest so the full install can be
  # smoke-tested without a UAC prompt. The real release build (default) uses
  # app.manifest (requireAdministrator).
  [switch]$NoElevate,
  # Where to write the setup exe; defaults to <repo>\dist\CommsuiteSetup.exe.
  [string]$Out = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $AppDir) { $AppDir = Join-Path $root "dist\app" }
if (-not (Test-Path -LiteralPath (Join-Path $AppDir "commsuite.exe"))) {
  throw "No Flutter Windows build found in '$AppDir'. Run: cd app; flutter build windows; then copy build\windows\x64\runner\Release\* to dist\app"
}

$project = Join-Path $PSScriptRoot "CommsuiteInstaller.csproj"
$obj = Join-Path $PSScriptRoot "obj"
$stage = Join-Path $obj "payload"
$payload = Join-Path $obj "payload.zip"

# --- 1. stage the app payload -------------------------------------------
# Never ship the <exe>.WebView2 folder: stale per-machine profiles break the
# in-app browser (same rule as the old NSIS File /x filter).
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
robocopy $AppDir $stage /E /XD *.WebView2 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
$global:LASTEXITCODE = 0

# --- 2. zip the payload ---------------------------------------------------
if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Force }
# Zip via the .NET API with retries: Windows Defender briefly locks freshly
# copied DLLs, which makes a single-shot Compress-Archive flaky.
Add-Type -AssemblyName System.IO.Compression.FileSystem
for ($attempt = 1; ; $attempt++) {
  try {
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
      $stage, $payload, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    break
  } catch {
    if ($attempt -ge 6) { throw "zipping the payload failed: $($_.Exception.Message)" }
    Write-Host "zip attempt $attempt failed ($($_.Exception.Message)); retrying..."
    Start-Sleep -Milliseconds 900
  }
}
$payloadSize = [math]::Round((Get-Item -LiteralPath $payload).Length / 1MB, 1)
Write-Host "payload.zip: $payloadSize MB"

# --- 3. small uninstaller (carried inside the setup exe) ------------------
# Rebuild first: wipes the shared bin/obj and leaves a clean slate. The Setup
# build below then recompiles for sure, because its own output assembly does
# not exist yet - and it must not clean, or it would delete the uninstaller
# it is about to embed.
$common = @("build", $project, "-c", $Configuration, "-v", "minimal")
if ($NoElevate) { $common += "-p:NoElevate=true" }

dotnet @common -p:Role=Uninstall -t:Rebuild
if ($LASTEXITCODE -ne 0) { throw "uninstaller build failed" }
$uninstaller = Join-Path $PSScriptRoot "bin\$Configuration\net48\CommsuiteUninstall.exe"
if (-not (Test-Path -LiteralPath $uninstaller)) { throw "uninstaller not produced at $uninstaller" }

# --- 4. setup exe with payload + uninstaller embedded ---------------------
dotnet @common -p:Role=Setup -p:PayloadZip="$payload" -p:UninstallerPath="$uninstaller"
if ($LASTEXITCODE -ne 0) { throw "setup build failed" }
$setup = Join-Path $PSScriptRoot "bin\$Configuration\net48\CommsuiteSetup.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw "setup exe not produced at $setup" }

if (-not $Out) { $Out = Join-Path $root "dist\CommsuiteSetup.exe" }
Copy-Item -LiteralPath $setup -Destination $Out -Force
$setupSize = [math]::Round((Get-Item -LiteralPath $Out).Length / 1MB, 1)
Write-Host ""
Write-Host "Built $Out ($setupSize MB)"
Write-Host "Install:   CommsuiteSetup.exe"
Write-Host "Silent:    CommsuiteSetup.exe /S [/D=C:\path]"
Write-Host "Uninstall: Uninstall.exe /uninstall [/S]  (from the install folder)"
