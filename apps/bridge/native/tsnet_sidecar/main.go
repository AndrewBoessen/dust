package main

import (
	"encoding/binary"
	"io"
	"log"
	"os"
	"path/filepath"

	"tailscale.com/tsnet"
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

		// TODO Route the payload to your networking functions
		response := handleCommand(srv, payload)

		// Write response header (number of bytes in response)
		respHeader := make([]byte, 4)
		binary.BigEndian.PutUint32(respHeader, uint32(len(response)))

		os.Stdout.Write(respHeader)
		os.Stdout.Write(response)
	}
}

func handleCommand(srv *tsnet.Server, cmd []byte) []byte {
	// TODO Add logic here (e.g., "GET_STATUS", "SEND_CHUNK", "DIAL_PEER")
	return append([]byte("ACK: "), cmd...)
}
