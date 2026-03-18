Mox.defmock(Dust.Bridge.Mock, for: Dust.Bridge.Behaviour)
Application.put_env(:dust_mesh, :bridge_module, Dust.Bridge.Mock)

ExUnit.start()
