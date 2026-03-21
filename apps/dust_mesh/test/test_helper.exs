Mox.defmock(Dust.Bridge.Mock, for: Dust.Bridge.Behaviour)
Application.put_env(:dust_mesh, :bridge_module, Dust.Bridge.Mock)

# Stop the application so tests have full control over supervised processes.
# Without this, the `mod:` auto-start conflicts with `start_supervised!`.
Application.stop(:dust_mesh)

ExUnit.start()
