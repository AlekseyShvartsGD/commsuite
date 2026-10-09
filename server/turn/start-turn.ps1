# Starts the Commsuite TURN relay (coturn) inside WSL2, listening on TCP/UDP 3478
# (reachable from Windows via 127.0.0.1 thanks to WSL2 localhost forwarding).
# Requires: WSL2 Ubuntu distro named "Ubuntu" with coturn installed (see README).
param(
  [string]$Distro = "Ubuntu"
)

$conf = "C:\Users\aleks\Desktop\alekz\server\turn\turnserver.conf"
$confWsl = "/mnt/c/Users/aleks/Desktop/alekz/server/turn/turnserver.conf"

Write-Host "Starting TURN server in WSL distro '$Distro'..."
wsl -d $Distro -u root -- bash -c "cp '$confWsl' /etc/turnserver.conf; nohup /usr/bin/turnserver -c /etc/turnserver.conf > /tmp/commsuite-turn.out 2>&1 & sleep 1; pgrep -ax turnserver"

Start-Sleep -Milliseconds 800
$open = $false
try {
  $c = New-Object System.Net.Sockets.TcpClient
  $r = $c.BeginConnect('127.0.0.1', 3478, $null, $null)
  $open = $r.AsyncWaitHandle.WaitOne(1500) -and $c.Connected
  $c.Close()
} catch {}
if ($open) {
  Write-Host "OK: TURN listening on 127.0.0.1:3478"
} else {
  Write-Warning "TURN did not come up on 127.0.0.1:3478 - check WSL logs."
}