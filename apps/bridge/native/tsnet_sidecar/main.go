package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"

	"tailscale.com/tsnet"
)

const (
	keyExchangePort = 9473
	keySize         = 32
)

func main() {
	// Configure the tsnet Server
	stateDir, _ := os.Getwd()
	srv := &tsnet.Server{
		Hostname: "dust-node",
		Dir:      filepath.Join(stateDir, "tsnet-state"),
		AuthKey:  os.Getenv("TS_AUTHKEY"),
	}
	defer srv.Close()

	// Start the Tailscale node
	if err := srv.Start(); err != nil {
		log.Fatalf("Failed to start tsnet: %v", err)
	}

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
	case "KEY_REQUEST":
		// KEY_REQUEST <peer_address>
		// Dial the peer over Tailscale to port 9473,
		// receive 32 bytes (the master key), and return them.
		if len(parts) < 2 {
			return []byte("ERR: KEY_REQUEST requires peer address")
		}
		peerAddr := strings.TrimSpace(parts[1])
		key, err := requestKeyFromPeer(srv, peerAddr)
		if err != nil {
			return []byte(fmt.Sprintf("ERR: %v", err))
		}
		// Return OK prefix + raw 32-byte key
		return append([]byte("OK:"), key...)

	case "KEY_SERVE":
		// KEY_SERVE <base64-key-bytes>
		// Start listening on the key exchange port and serve the
		// provided key to any connecting peer. Runs in a goroutine
		// so the port loop remains responsive.
		if len(parts) < 2 || len(parts[1]) < keySize {
			return []byte("ERR: KEY_SERVE requires 32-byte key payload")
		}
		keyBytes := []byte(parts[1])[:keySize]
		go serveKeyToPeers(srv, keyBytes)
		return []byte("OK: key server started")

	case "GET_STATUS":
		return []byte("OK: running")

	default:
		return append([]byte("ACK: "), cmd...)
	}
}

// requestKeyFromPeer dials a peer over Tailscale and reads 32 bytes.
func requestKeyFromPeer(srv *tsnet.Server, peerAddr string) ([]byte, error) {
	conn, err := srv.Dial("tcp", fmt.Sprintf("%s:%d", peerAddr, keyExchangePort))
	if err != nil {
		return nil, fmt.Errorf("failed to dial peer %s: %w", peerAddr, err)
	}
	defer conn.Close()

	// Send a simple request marker
	_, err = conn.Write([]byte("KEY_REQUEST"))
	if err != nil {
		return nil, fmt.Errorf("failed to send request: %w", err)
	}

	// Read the 32-byte key response
	key := make([]byte, keySize)
	if _, err := io.ReadFull(conn, key); err != nil {
		return nil, fmt.Errorf("failed to read key: %w", err)
	}

	return key, nil
}

// serveKeyToPeers listens on the key exchange port and sends the master
// key to any peer that connects. Tailscale's WireGuard tunnel provides
// encryption, so the key is sent in the clear over the tunnel.
func serveKeyToPeers(srv *tsnet.Server, key []byte) {
	ln, err := srv.Listen("tcp", fmt.Sprintf(":%d", keyExchangePort))
	if err != nil {
		log.Printf("KEY_SERVE: failed to listen: %v", err)
		return
	}
	defer ln.Close()

	log.Printf("KEY_SERVE: listening on :%d", keyExchangePort)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("KEY_SERVE: accept error: %v", err)
			return
		}
		go handleKeyClient(conn, key)
	}
}

func handleKeyClient(conn net.Conn, key []byte) {
	defer conn.Close()

	// Read the request marker (up to 32 bytes)
	buf := make([]byte, 32)
	n, err := conn.Read(buf)
	if err != nil {
		log.Printf("KEY_SERVE: read error: %v", err)
		return
	}

	if string(buf[:n]) != "KEY_REQUEST" {
		log.Printf("KEY_SERVE: unexpected request: %s", string(buf[:n]))
		return
	}

	// Send the key
	if _, err := conn.Write(key); err != nil {
		log.Printf("KEY_SERVE: write error: %v", err)
	}
}
