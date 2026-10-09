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

wsl -d $Distro -- true
if ($LASTEXITCODE -ne 0) {
  Write-Warning "WSL distro '$Distro' is not available."
  exit 1
}

Write-Host "Running orchestrator in WSL distro '$Distro' ..."
wsl -d $Distro -- bash "$script"

Write-Host ""
Write-Host "Node/TURN/mux run inside WSL; tunnels go public instantly."
Write-Host "Endpoints are STABLE once registered; to see them run:"
Write-Host "  wsl -d $Distro -- sh -c `"grep cloudpub.ru /tmp/commsuite-logs/clo-run.log | tail -2`""
Write-Host "Then in the app: Server address = the https://...cloudpub.ru line, TURN tcp.cloudpub.ru:<port from tcp line> (commsuite/commsuite-1)."