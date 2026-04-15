defmodule Dust.Bridge.EPMDTest do
  use ExUnit.Case, async: true

  alias Dust.Bridge.EPMD

  setup_all do
    Application.stop(:dust_bridge)

    on_exit(fn -> Application.ensure_all_started(:dust_bridge) end)
  end

  # ── Stub functions required by :erl_epmd ──────────────────────────────

  describe "start_link/0" do
    test "returns :ignore" do
      assert EPMD.start_link() == :ignore
    end
  end

  describe "register_node/2" do
    test "returns {:ok, 1}" do
      assert EPMD.register_node(~c"dust", 9000) == {:ok, 1}
    end
  end

  describe "register_node/3" do
    test "returns {:ok, 1} for any family" do
      assert EPMD.register_node(~c"dust", 9000, :inet) == {:ok, 1}
      assert EPMD.register_node(~c"dust", 9000, :inet6) == {:ok, 1}
    end
  end

  describe "names/1" do
    test "returns {:error, :address}" do
      assert EPMD.names(~c"localhost") == {:error, :address}
    end
  end

  describe "listen_port_please/2" do
    test "returns {:ok, 9000}" do
      assert EPMD.listen_port_please(~c"dust", ~c"localhost") == {:ok, 9000}
    end

    test "returns the same port regardless of arguments" do
      assert EPMD.listen_port_please(~c"other", ~c"10.0.0.1") == {:ok, 9000}
    end
  end
end
