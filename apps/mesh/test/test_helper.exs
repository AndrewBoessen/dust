Mox.defmock(Bridge.Mock, for: Bridge.Behaviour)
Application.put_env(:mesh, :bridge_module, Bridge.Mock)

ExUnit.start()
