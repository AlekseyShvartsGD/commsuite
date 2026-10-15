# Commsuite all-in-one launcher (Windows side).
# Starts the TURN relay (coturn in WSL2), the Node API server, and CloudPub
# public tunnels - all inside the WSL2 "Ubuntu" distro, talking over loopback.
#
# Usage:
#   .\server\turn\start-all.ps1            # everything
#   .\server\turn\start-all.ps1 -TurnOnly  # just the TURN relay
param(
  [string]$Distro = "Ubuntu",
  [switch]$TurnOnly
)

$script = "/mnt/c/Users/aleks/Desktop/alekz/server/turn/start-all.sh"
if ($TurnOnly) {
  $script = "/mnt/c/Users/aleks/Desktop/alekz/server/turn/start-turn.sh"
}

# Uploads the live public URL to a small pointer file in the GitHub repo so an
# app whose saved (random CloudPub) address went stale can discover the new
# one. Uses the persistent user token COMMSUITE_GH_TOKEN; a no-op without it or
# when the address has not changed.
function Publish-PublicUrl {
  param([string]$Url)
  $token = $env:COMMSUITE_GH_TOKEN
  if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "Skipping pointer publish (COMMSUITE_GH_TOKEN not set)."
    return
  }
  $apiUrl = 'https://api.github.com/repos/AlekseyShvartsGD/commsuite/contents/public-url.json'
  $headers = @{
    Authorization = "Bearer $token"
    Accept        = 'application/vnd.github+json'
    'User-Agent'  = 'commsuite-publisher'
  }
  $content = (@{ url = $Url; updated = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } |
      ConvertTo-Json -Compress)

  $sha = $null
  try {
    $cur = Invoke-RestMethod -Method Get -Uri $apiUrl -Headers $headers
    $sha = $cur.sha
    $existing = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String(($cur.content -replace '\s', '')))
    if ((($existing | ConvertFrom-Json).url) -eq $Url) {
      Write-Host "Discovery pointer already current: $Url"
      return
    }
  } catch {
    # 404 (no pointer yet) or transient error: fall through and try to write.
  }

  $body = @{
    message = 'chore: update published server url'
    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    branch  = 'main'
  }
  if ($sha) { $body.sha = $sha }
  try {
    Invoke-RestMethod -Method Put -Uri $apiUrl -Headers $headers `
      -ContentType 'application/json' -Body ($body | ConvertTo-Json) | Out-Null
    Write-Host "Published discovery pointer: $Url"
  } catch {
    Write-Warning "Could not publish discovery pointer: $($_.Exception.Message)"
  }
}

wsl -d $Distro -- true
if ($LASTEXITCODE -ne 0) {
  Write-Warning "WSL distro '$Distro' is not available."
  exit 1
}

Write-Host "Running orchestrator in WSL distro '$Distro' ..."
wsl -d $Distro -- bash "$script"

if (-not $TurnOnly) {
  $clo = "/mnt/c/Users/aleks/Desktop/alekz/tools/cloudpub-linux/clo"
  $url = (wsl -d $Distro -- $clo ls 2>$null |
      Select-String -Pattern 'https://[a-z0-9-]+\.cloudpub\.ru' -AllMatches |
      ForEach-Object { $_.Matches.Value } | Select-Object -First 1)
  if ($url) {
    Write-Host "Public URL: $url"
    Publish-PublicUrl -Url $url
  } else {
    Write-Warning "Could not read the public URL from CloudPub (is the tunnel up?)."
  }
}

Write-Host ""
Write-Host "Node/TURN/mux run inside WSL; tunnels go public instantly."
Write-Host "Endpoints are STABLE once registered; to see them run:"
Write-Host "  wsl -d $Distro -- sh -c `"grep cloudpub.ru /tmp/commsuite-logs/clo-run.log | tail -2`""
Write-Host "Then in the app: Server address = the https://...cloudpub.ru line, TURN tcp.cloudpub.ru:<port from tcp line> (commsuite/commsuite-1)."
