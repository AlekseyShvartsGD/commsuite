param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Notes = "",
  [string]$Repo = "",                 # owner/name of a PUBLIC repo used for releases
  [string]$Installer = "",            # defaults to <root>\update\commsuite-setup.exe
  [string]$Apk = "",
  [string]$Linux = "",
  [string]$Token = "",                 # falls back to $env:COMMSUITE_GH_TOKEN
  [switch]$SkipSha256                  # do not attach the SHA256SUMS asset
)
# Publishes the release artifacts to GitHub Releases and prints the URLs to feed
# publish-manifest.ps1 as *Mirror parameters, so clients download from a host
# with a clean reputation instead of the CloudPub hostname.
#
# The token is only ever read from the environment (or -Token) and is never
# written to disk, logged, or committed.
$ErrorPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$api = "https://api.github.com"
$uploads = "https://uploads.github.com"

# A `setx` in another terminal writes the user environment but not the
# environment of an already-running process, so fall back to the registry.
$userEnv = Get-ItemProperty -Path "HKCU:\Environment" -ErrorAction SilentlyContinue
if (-not $Repo) { $Repo = $env:COMMSUITE_GH_REPO }
if (-not $Repo -and $userEnv) { $Repo = $userEnv.COMMSUITE_GH_REPO }
if (-not $Repo) { throw "Pass -Repo owner/name or set COMMSUITE_GH_REPO" }
if ($Repo -notmatch '^[^/]+/[^/]+$') { throw "Repo must look like owner/name (got '$Repo')" }

$tok = if ($Token) { $Token } elseif ($env:COMMSUITE_GH_TOKEN) { $env:COMMSUITE_GH_TOKEN } else { $null }
if (-not $tok -and $userEnv) { $tok = $userEnv.COMMSUITE_GH_TOKEN }
if (-not $tok) { throw "No token: set COMMSUITE_GH_TOKEN (a token with contents:write on $Repo)" }

if (-not $Installer) { $Installer = Join-Path $root "update\commsuite-setup.exe" }
$headers = @{
  Authorization        = "Bearer $tok"
  Accept               = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
  "User-Agent"         = "commsuite-publisher"
}

function Invoke-Gh {
  param([string]$Method, [string]$Url, $Body)
  try {
    if ($null -ne $Body) {
      return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -Body ($Body | ConvertTo-Json -Depth 6) -ContentType 'application/json'
    }
    return Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers
  } catch {
    $detail = $_.Exception.Message
    if ($_.Exception.Response) {
      try {
        $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
        $detail = $reader.ReadToEnd()
      } catch {}
    }
    throw "GitHub $Method $Url failed: $detail"
  }
}

# A release needs at least one commit to hang its tag on; seed a README when
# the mirror repo is still empty.
$repoInfo = Invoke-Gh GET "$api/repos/$Repo"
$hasReadme = $false
try {
  Invoke-Gh GET "$api/repos/$Repo/contents/README.md" | Out-Null
  $hasReadme = $true
} catch {}
if (-not $hasReadme) {
  Write-Output "seeding README.md in $Repo"
  $readme = [Text.Encoding]::UTF8.GetBytes("# Commsuite releases`n`nBinary releases live here as GitHub Release assets. The app reads /update/latest.json from its own server, which lists these assets as mirrors.`n")
  $payload = @{ message = "Add README"; content = [Convert]::ToBase64String($readme) } | ConvertTo-Json -Depth 4
  try {
    Invoke-RestMethod -Method PUT -Uri "$api/repos/$Repo/contents/README.md" -Headers $headers -Body $payload -ContentType 'application/json' | Out-Null
  } catch {
    Write-Output "could not seed README ($($_.Exception.Message)); continuing"
  }
}

$tag = "v$Version"
$release = $null
try {
  $release = Invoke-Gh GET "$api/repos/$Repo/releases/tags/$tag"
  Write-Output "reusing release $tag (id $($release.id))"
} catch {
  $release = Invoke-Gh POST "$api/repos/$Repo/releases" @{
    tag_name    = $tag
    name        = "Commsuite $Version"
    body        = if ($Notes) { $Notes } else { "Commsuite $Version" }
    draft       = $false
    prerelease  = $false
  }
  Write-Output "created release $tag (id $($release.id))"
}

# Collect artifacts: only files that actually exist, named so the URLs stay
# stable (the manifest appends these exact names to the release URL).
$assets = @()
if (Test-Path -LiteralPath $Installer) { $assets += (Get-Item -LiteralPath $Installer) }
if ($Apk -and (Test-Path -LiteralPath $Apk)) { $assets += (Get-Item -LiteralPath $Apk) }
if ($Linux -and (Test-Path -LiteralPath $Linux)) { $assets += (Get-Item -LiteralPath $Linux) }
if ($assets.Count -eq 0) { throw "No artifacts found to publish (checked installer '$Installer', apk '$Apk', linux '$Linux')" }

# SHA256SUMS so the release is verifiable by hand (opt-out via -SkipSha256).
$lines = foreach ($a in $assets) {
  "$((Get-FileHash -LiteralPath $a.FullName -Algorithm SHA256).Hash.ToLower())  $($a.Name)"
}
if ($SkipSha256) {
  Write-Output "skipping SHA256SUMS asset (-SkipSha256)"
} else {
  $sums = Join-Path $env:TEMP "commsuite-sha256sums-$Version.txt"
  Set-Content -LiteralPath $sums -Value $lines -Encoding ascii
  $assets += (Get-Item -LiteralPath $sums)
}

# Replace assets with the same name (re-running a release must overwrite).
$existing = @{}
try {
  foreach ($a in (Invoke-Gh GET "$api/repos/$Repo/releases/$($release.id)/assets?per_page=100")) { $existing[$a.name] = $a.id }
} catch {}

$downloaded = @()
foreach ($a in $assets) {
  if ($existing.ContainsKey($a.Name)) {
    Write-Output "removing stale asset $($a.Name)"
    Invoke-Gh DELETE "$api/repos/$Repo/releases/assets/$($existing[$a.Name])" | Out-Null
  }
  $url = "$uploads/repos/$Repo/releases/$($release.id)/assets?name=$([uri]::EscapeDataString($a.Name))"
  Write-Output ("uploading {0} ({1:N0} bytes)" -f $a.Name, $a.Length)
  # Invoke-WebRequest keeps the token in a header (not on a command line, where
  # any local process could read it) and streams the file with -InFile.
  try {
    $resp = Invoke-WebRequest -UseBasicParsing -Method POST -Uri $url -Headers $headers -InFile $a.FullName -ContentType 'application/octet-stream' -TimeoutSec 900
  } catch {
    $detail = $_.Exception.Message
    if ($_.Exception.Response) {
      try {
        $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
        $detail = $reader.ReadToEnd()
      } catch {}
    }
    throw "upload of $($a.Name) failed: $detail"
  }
  $json = $resp.Content | ConvertFrom-Json
  Write-Output ("  -> {0} ({1:N0} bytes)" -f $json.browser_download_url, $json.size)
  $downloaded += $json.browser_download_url
}

Write-Output ""
Write-Output "Release $tag published to https://github.com/$Repo/releases/tag/$tag"
Write-Output "Now re-publish the manifest so clients prefer these URLs:"
$base = "https://github.com/$Repo/releases/download/$tag"
$args = @('-Version', $Version)
if ($Notes) { $args += @('-Notes', $Notes) }
if ($assets | Where-Object { $_.Name -eq 'commsuite-setup.exe' }) { $args += @('-InstallerMirror', $base) }
if ($assets | Where-Object { $_.Name -eq 'commsuite.apk' }) { $args += @('-ApkMirror', $base) }
if ($assets | Where-Object { $_.Name -like 'commsuite-linux-*' }) { $args += @('-LinuxMirror', $base) }
Write-Output "  .\publish-manifest.ps1 $($args -join ' ')"
if ($sums) { Remove-Item -LiteralPath $sums -Force -ErrorAction SilentlyContinue }
