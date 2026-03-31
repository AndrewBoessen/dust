# Stop the real bridge application so the Go sidecar doesn't start.
# Tests manage their own processes via start_supervised!/1.
Application.stop(:dust_bridge)

ExUnit.start()
