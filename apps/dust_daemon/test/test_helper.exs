ExUnit.start()

unless Code.ensure_loaded?(Dust.Bridge.Mock) do
  Mox.defmock(Dust.Bridge.Mock, for: Dust.Bridge.Behaviour)
end

Application.put_env(:dust_bridge, :bridge_module, Dust.Bridge.Mock)
