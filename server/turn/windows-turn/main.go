// Native-Windows TURN relay for Commsuite calls.
//
// Runs outside WSL on purpose: a WSL2 mirrored-network socket is only reachable
// from Windows via loopback, so an in-WSL relay can never serve both a Windows
// peer (127.0.0.1) and an emulator peer (10.0.2.2). Binding on the real host
// interface gives both peers one shared, reachable relay address.
//
// Build:  go build -o turnserver.exe .
// Run:    .\turnserver.exe
//
// Env overrides:
//   TURN_LISTEN      listen address:port (default 0.0.0.0:3478)
//   TURN_EXTERNAL_IP relay IP advertised to clients (default 192.168.0.146)
//   TURN_REALM       auth realm (default commsuite.local)
//   TURN_USER        username (default commsuite)
//   TURN_PASS        password (default commsuite-1)
//   TURN_MIN_PORT    relay port range start (default 49152)
//   TURN_MAX_PORT    relay port range end (default 49200)
package main

import (
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"github.com/pion/turn/v4"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	realm := env("TURN_REALM", "commsuite.local")
	relayIP := net.ParseIP(env("TURN_EXTERNAL_IP", "192.168.0.146"))
	if relayIP == nil {
		log.Fatal("invalid TURN_EXTERNAL_IP")
	}
	listen := env("TURN_LISTEN", "0.0.0.0:3478")

	minPort, err := strconv.Atoi(env("TURN_MIN_PORT", "49152"))
	if err != nil {
		log.Fatal("invalid TURN_MIN_PORT")
	}
	maxPort, err := strconv.Atoi(env("TURN_MAX_PORT", "49200"))
	if err != nil {
		log.Fatal("invalid TURN_MAX_PORT")
	}

	user := env("TURN_USER", "commsuite")
	pass := env("TURN_PASS", "commsuite-1")

	authHandler := func(username, realm string, _ net.Addr) ([]byte, bool) {
		if username == user {
			return turn.GenerateAuthKey(username, realm, pass), true
		}
		return nil, false
	}

	udpListener, err := net.ListenPacket("udp4", listen)
	if err != nil {
		log.Fatalf("udp listen %s: %v", listen, err)
	}
	tcpListener, err := net.Listen("tcp4", listen)
	if err != nil {
		log.Fatalf("tcp listen %s: %v", listen, err)
	}

	udpGen := &turn.RelayAddressGeneratorPortRange{
		RelayAddress: relayIP,
		Address:      "0.0.0.0",
		MinPort:      uint16(minPort),
		MaxPort:      uint16(maxPort),
	}
	tcpGen := &turn.RelayAddressGeneratorPortRange{
		RelayAddress: relayIP,
		Address:      "0.0.0.0",
		MinPort:      uint16(minPort),
		MaxPort:      uint16(maxPort),
	}

	server, err := turn.NewServer(turn.ServerConfig{
		Realm:       realm,
		AuthHandler: authHandler,
		PacketConnConfigs: []turn.PacketConnConfig{
			{PacketConn: udpListener, RelayAddressGenerator: udpGen},
		},
		ListenerConfigs: []turn.ListenerConfig{
			{Listener: tcpListener, RelayAddressGenerator: tcpGen},
		},
	})
	if err != nil {
		log.Fatalf("turn server: %v", err)
	}

	log.Printf("Commsuite TURN listening on %s  realm=%s  relay=%s  ports=%d-%d  user=%s",
		listen, realm, relayIP, minPort, maxPort, user)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	_ = server.Close()
}
