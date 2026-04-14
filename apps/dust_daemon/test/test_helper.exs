ExUnit.start()

unless Code.ensure_loaded?(Dust.Bridge.Mock) do
  Mox.defmock(Dust.Bridge.Mock, for: Dust.Bridge.Behaviour)
end

Application.put_env(:dust_bridge, :bridge_module, Dust.Bridge.Mock)

# The bootstrapper does not run in the test environment, so mark
# the system as ready so sweep guards in GC/RepairScheduler pass.
Dust.Daemon.Readiness.set_ready()
