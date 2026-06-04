ExUnit.start()

unless Code.ensure_loaded?(Dust.Bridge.Mock) do
  Mox.defmock(Dust.Bridge.Mock, for: Dust.Bridge.Behaviour)
end

Application.put_env(:dust_bridge, :bridge_module, Dust.Bridge.Mock)

# Remove any stale master.key persisted by a previous test run with a
# different password — otherwise KeyStore.unlock/1 silently fails with
# {:error, :decrypt_failed} and downstream encrypt_with_master/1 raises.
File.rm(Dust.Utilities.File.master_key_file())

# Unlock the KeyStore once so every test that does encryption can run.
:ok = Dust.Core.KeyStore.unlock("test_password_123")

# The bootstrapper does not run in the test environment, so mark
# the system as ready so sweep guards in GC/RepairScheduler pass.
Dust.Daemon.Readiness.set_ready()
