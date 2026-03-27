Mox.defmock(Dust.Bridge.Mock, for: Dust.Bridge.Behaviour)
Application.put_env(:dust_mesh, :bridge_module, Dust.Bridge.Mock)

# Stop the application so tests have full control over supervised processes.
# Without this, the `mod:` auto-start conflicts with `start_supervised!`.
Application.stop(:dust_mesh)

# Clean up old test DBs
File.rm_rf!(Path.join(System.tmp_dir!(), "dust_mesh_test_data"))

ExUnit.start()
