# Stop the application so tests have full control over supervised processes.
# Without this, the `mod:` auto-start conflicts with `start_supervised!`.
Application.stop(:dust_core)

ExUnit.start()
