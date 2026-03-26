package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/tailscale"
	"tailscale.com/tsnet"
)

const (
	keyExchangePort = 9473
)

var (
	inviteTokens   = make(map[string]time.Time)
	inviteTokensMu sync.Mutex
	masterSecrets  []byte
)

func main() {
	// Configure the tsnet Server
	hostname := os.Getenv("TS_HOSTNAME")
	if hostname == "" {
		hostname = "dust-node"
	}

	stateDir := os.Getenv("TS_STATE_DIR")
	if stateDir == "" {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			homeDir, _ = os.Getwd()
		}
		stateDir = filepath.Join(homeDir, ".dust", "tsnet-state-"+hostname)
	}

	srv := &tsnet.Server{
		Hostname: hostname,
		Dir:      stateDir,
		AuthKey:  os.Getenv("TS_AUTHKEY"),
	}
	defer srv.Close()

	// Start the Tailscale node
	if err := srv.Start(); err != nil {
		log.Fatalf("Failed to start tsnet: %v", err)
	}

	// Wait for the node to be connected to the Tailnet in the background
	// so the Elixir port loop doesn't block while waiting for auth.
	go func() {
		if _, err := srv.Up(context.Background()); err != nil {
			log.Printf("Failed to connect to tailnet: %v", err)
		}
	}()

	// The Port Communication Loop
	// Elixir uses BigEndian for {:packet, 4}
	for {
		// Read the 4-byte length header
		header := make([]byte, 4)
		if _, err := io.ReadFull(os.Stdin, header); err != nil {
			if err == io.EOF {
				break // port closed
			}
			continue
		}

		length := binary.BigEndian.Uint32(header)
		payload := make([]byte, length)
		if _, err := io.ReadFull(os.Stdin, payload); err != nil {
			break
		}

		response := handleCommand(srv, payload)

		// Write response header (number of bytes in response)
		respHeader := make([]byte, 4)
		binary.BigEndian.PutUint32(respHeader, uint32(len(response)))

		os.Stdout.Write(respHeader)
		os.Stdout.Write(response)
	}
}

func handleCommand(srv *tsnet.Server, cmd []byte) []byte {
	parts := strings.SplitN(string(cmd), " ", 2)
	command := parts[0]

	switch command {
	case "JOIN":
		// JOIN <peer_address> <token>
		if len(parts) < 2 {
			return []byte("ERR: JOIN requires peer address and token")
		}
		joinArgs := strings.SplitN(parts[1], " ", 2)
		if len(joinArgs) < 2 {
			return []byte("ERR: JOIN requires peer address and token")
		}
		peerAddr := strings.TrimSpace(joinArgs[0])
		token := strings.TrimSpace(joinArgs[1])
		secrets, err := joinPeer(srv, peerAddr, token)
		if err != nil {
			return []byte(fmt.Sprintf("ERR: %v", err))
		}
		return append([]byte("OK:"), secrets...)

	case "SERVE_SECRETS":
		// SERVE_SECRETS <master_key_b64>:<otp_cookie>
		if len(parts) < 2 {
			return []byte("ERR: SERVE_SECRETS requires payload")
		}
		masterSecrets = []byte(parts[1])
		go serveSecretsToPeers(srv)
		return []byte("OK: secret server started")

	case "INVITE_CREATE":
		// INVITE_CREATE <token>
		if len(parts) < 2 {
			return []byte("ERR: INVITE_CREATE requires token")
		}
		token := strings.TrimSpace(parts[1])
		inviteTokensMu.Lock()
		inviteTokens[token] = time.Now().Add(10 * time.Minute)
		inviteTokensMu.Unlock()
		return []byte("OK: invite created")

	case "PEERS":
		lc, err := srv.LocalClient()
		if err != nil {
			return []byte(fmt.Sprintf("ERR: %v", err))
		}
		st, err := lc.Status(context.Background())
		if err != nil {
			return []byte(fmt.Sprintf("ERR: %v", err))
		}
		var ips []string
		for _, peer := range st.Peer {
			if len(peer.TailscaleIPs) > 0 {
				ips = append(ips, peer.TailscaleIPs[0].String())
			}
		}
		return []byte("OK:" + strings.Join(ips, ","))

	case "PROXY":
		// PROXY <targetIP> <targetPort>
		if len(parts) < 2 {
			return []byte("ERR: PROXY requires target IP and port")
		}
		target := strings.TrimSpace(parts[1])
		localLn, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return []byte(fmt.Sprintf("ERR: %v", err))
		}
		go proxyOutgoing(srv, localLn, target)
		addr := localLn.Addr().(*net.TCPAddr)
		return []byte(fmt.Sprintf("OK:%d", addr.Port))

	case "EXPOSE":
		// EXPOSE <port>
		if len(parts) < 2 {
			return []byte("ERR: EXPOSE requires port number")
		}
		portStr := strings.TrimSpace(parts[1])
		go exposeIncoming(srv, portStr)
		return []byte("OK: exposed " + portStr)

	case "GET_STATUS":
		return []byte("OK: running")

	default:
		return append([]byte("ACK: "), cmd...)
	}
}

func proxyOutgoing(srv *tsnet.Server, ln net.Listener, target string) {
	defer ln.Close()
	for {
		localConn, err := ln.Accept()
		if err != nil {
			return
		}
		go func(lConn net.Conn) {
			defer lConn.Close()
			tConn, err := srv.Dial(context.Background(), "tcp", target)
			if err != nil {
				log.Printf("PROXY dial error: %v", err)
				return
			}
			defer tConn.Close()
			errc := make(chan error, 2)
			go func() {
				_, err := io.Copy(tConn, lConn)
				errc <- err
			}()
			go func() {
				_, err := io.Copy(lConn, tConn)
				errc <- err
			}()
			<-errc
		}(localConn)
	}
}

func exposeIncoming(srv *tsnet.Server, portStr string) {
	ln, err := srv.Listen("tcp", ":"+portStr)
	if err != nil {
		log.Printf("EXPOSE listen error: %v", err)
		return
	}
	defer ln.Close()
	lc, err := srv.LocalClient()
	if err != nil {
		log.Printf("EXPOSE localclient error: %v", err)
		return
	}
	for {
		tsConn, err := ln.Accept()
		if err != nil {
			return
		}
		go func(tConn net.Conn) {
			defer tConn.Close()
			whois, err := lc.WhoIs(context.Background(), tConn.RemoteAddr().String())
			if err != nil || whois == nil || whois.Node == nil {
				log.Printf("EXPOSE unauthenticated peer: %v", tConn.RemoteAddr())
				return
			}
			localConn, err := net.Dial("tcp", "127.0.0.1:"+portStr)
			if err != nil {
				log.Printf("EXPOSE dial local error: %v", err)
				return
			}
			defer localConn.Close()
			errc := make(chan error, 2)
			go func() {
				io.Copy(localConn, tConn)
				errc <- nil
			}()
			go func() {
				io.Copy(tConn, localConn)
				errc <- nil
			}()
			<-errc
		}(tsConn)
	}
}

// joinPeer dials a peer over Tailscale and requests secrets using a token.
func joinPeer(srv *tsnet.Server, peerAddr, token string) ([]byte, error) {
	conn, err := srv.Dial(context.Background(), "tcp", fmt.Sprintf("%s:%d", peerAddr, keyExchangePort))
	if err != nil {
		return nil, fmt.Errorf("failed to dial peer %s: %w", peerAddr, err)
	}
	defer conn.Close()

	// Send token
	_, err = conn.Write([]byte(token))
	if err != nil {
		return nil, fmt.Errorf("failed to send token: %w", err)
	}

	// Read response secrets
	secrets, err := io.ReadAll(conn)
	if err != nil {
		return nil, fmt.Errorf("failed to read secrets: %w", err)
	}
	if strings.HasPrefix(string(secrets), "ERR:") {
		return nil, fmt.Errorf("server rejected: %s", string(secrets))
	}
	return secrets, nil
}

func serveSecretsToPeers(srv *tsnet.Server) {
	ln, err := srv.Listen("tcp", fmt.Sprintf(":%d", keyExchangePort))
	if err != nil {
		log.Printf("SERVE_SECRETS: failed to listen: %v", err)
		return
	}
	defer ln.Close()

	lc, err := srv.LocalClient()
	if err != nil {
		log.Printf("SERVE_SECRETS: localclient error: %v", err)
		return
	}

	log.Printf("SERVE_SECRETS: listening on :%d", keyExchangePort)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("SERVE_SECRETS: accept error: %v", err)
			return
		}
		go handleSecretClient(conn, lc)
	}
}

func handleSecretClient(conn net.Conn, lc *tailscale.LocalClient) {
	defer conn.Close()

	whois, err := lc.WhoIs(context.Background(), conn.RemoteAddr().String())
	if err != nil || whois == nil || whois.Node == nil {
		conn.Write([]byte("ERR: Unauthorized Tailscale Identity"))
		return
	}

	buf := make([]byte, 32)
	n, err := io.ReadFull(conn, buf)
	if err != nil {
		log.Printf("SERVE_SECRETS: read token error: %v", err)
		conn.Write([]byte("ERR: Invalid token format"))
		return
	}
	token := string(buf[:n])

	valid := false
	inviteTokensMu.Lock()
	now := time.Now()
	for k, v := range inviteTokens {
		if now.After(v) {
			delete(inviteTokens, k)
		}
	}
	if expiration, exists := inviteTokens[token]; exists {
		if now.Before(expiration) {
			delete(inviteTokens, token)
			valid = true
		}
	}
	inviteTokensMu.Unlock()

	if !valid {
		conn.Write([]byte("ERR: Invalid or expired token"))
		return
	}

	if _, err := conn.Write(masterSecrets); err != nil {
		log.Printf("SERVE_SECRETS: write error: %v", err)
	}
}
