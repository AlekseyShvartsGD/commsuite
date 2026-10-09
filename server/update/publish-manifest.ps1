param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Notes = "",
  [string]$Apk = "",
  [string]$Linux = "",
  [string]$WindowsVersion = "",
  [string]$ApkVersion = "",
  [string]$LinuxVersion = "",
  # Optional absolute mirror URLs tried by the app before the primary host.
  # Use these when the CloudPub hostname is blocked or carries a browser
  # reputation warning: the update still installs, from a reputable host.
  [string]$InstallerMirror = "",
  [string]$ApkMirror = "",
  [string]$LinuxMirror = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$winV = if ($WindowsVersion) { $WindowsVersion } else { $Version }
$apkV = if ($ApkVersion) { $ApkVersion } else { $Version }
$linV = if ($LinuxVersion) { $LinuxVersion } else { $Version }

function Get-MaxVersion {
  param([string[]]$Versions)
  $max = ""
  foreach ($v in $Versions) {
    if ($max -eq "") { $max = $v; continue }
    $vp = $v -split '\.'
    $mp = $max -split '\.'
    $n = [Math]::Max($vp.Length, $mp.Length)
    for ($i = 0; $i -lt $n; $i++) {
      $x = if ($i -lt $vp.Length) { [int]$vp[$i] } else { 0 }
      $y = if ($i -lt $mp.Length) { [int]$mp[$i] } else { 0 }
      if ($x -gt $y) { $max = $v; break }
      if ($x -lt $y) { break }
    }
  }
  return $max
}
$globalV = Get-MaxVersion @($winV, $apkV, $linV)

# Per-platform versions: a release that only bumps (say) Linux must not trigger
# an update prompt on Windows/Android. Top-level 'version' stays the newest of
# the three so older clients (which only understand 'version') still see the
# release as available once.
$manifest = @{
  version        = $globalV
  windowsVersion = $winV
  apkVersion     = $apkV
  linuxVersion   = $linV
  notes          = $Notes
  publishedAt    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

$exe = Join-Path $root "update\commsuite-setup.exe"
if (Test-Path -LiteralPath $exe) {
  $item = Get-Item -LiteralPath $exe
  $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower()
  $manifest["installer"]       = "/update/commsuite-setup.exe"
  $manifest["installerSize"]   = $item.Length
  $manifest["installerSha256"] = $hash
  Write-Output "installer: $($item.Length) bytes, sha256 $hash"
} else {
  Write-Output "no commsuite-setup.exe present (skipping installer metadata)"
}
if ($Apk -and (Test-Path -LiteralPath $Apk)) {
  $apkItem = Get-Item -LiteralPath $Apk
  $apkHash = (Get-FileHash -LiteralPath $Apk -Algorithm SHA256).Hash.ToLower()
  $manifest["apk"]       = "/update/commsuite.apk"
  $manifest["apkSize"]   = $apkItem.Length
  $manifest["apkSha256"] = $apkHash
  Write-Output "apk: $($apkItem.Length) bytes, sha256 $apkHash"
} else {
  Write-Output "no apk provided (skipping apk metadata)"
}
if ($Linux -and (Test-Path -LiteralPath $Linux)) {
  $linuxItem = Get-Item -LiteralPath $Linux
  $linuxHash = (Get-FileHash -LiteralPath $Linux -Algorithm SHA256).Hash.ToLower()
  $manifest["linux"]       = "/update/$([IO.Path]::GetFileName($Linux))"
  $manifest["linuxSize"]   = $linuxItem.Length
  $manifest["linuxSha256"] = $linuxHash
  Write-Output "linux: $($linuxItem.Length) bytes, sha256 $linuxHash"
} else {
  Write-Output "no linux provided (skipping linux metadata)"
}
# Mirrors are only meaningful once the files are actually reachable there, so
# they are advertised last: publish the artifacts to the mirror host first,
# re-run this script with the mirror URLs, and the app will prefer them.
$mirrors = @{}
if ($InstallerMirror) { $mirrors["installer"] = "$($InstallerMirror.TrimEnd('/'))/$([IO.Path]::GetFileName($exe))" }
if ($ApkMirror -and (Test-Path -LiteralPath $Apk)) { $mirrors["apk"] = "$($ApkMirror.TrimEnd('/'))/$([IO.Path]::GetFileName($Apk))" }
if ($LinuxMirror -and $Linux) { $mirrors["linux"] = "$($LinuxMirror.TrimEnd('/'))/$([IO.Path]::GetFileName($Linux))" }
if ($mirrors.Count -gt 0) {
  $manifest["mirrors"] = $mirrors
  Write-Output "mirrors:"
  $mirrors.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Output "  $($_.Key): $($_.Value -join ', ')" }
}
Set-Content -LiteralPath (Join-Path $root "update\latest.json") -Value ($manifest | ConvertTo-Json) -Encoding ascii
Write-Output "published $globalV (windows $winV / apk $apkV / linux $linV)"