defmodule Dust.BridgeTest do
  use ExUnit.Case

  # These tests start Dust.Bridge with a fake sidecar script that speaks
  # the same {:packet, 4} wire protocol. This lets us exercise the full
  # GenServer ↔ Port round-trip and verify response parsing without the
  # real Go binary.

  @fake_sidecar Path.expand("support/fake_sidecar", __DIR__)

  setup_all do
    Application.stop(:dust_bridge)

    on_exit(fn -> Application.ensure_all_started(:dust_bridge) end)
  end

  setup do
    # Find the elixir executable to run our fake sidecar script
    elixir_path = System.find_executable("elixir")

    # Build a wrapper script that execs elixir with the fake sidecar.
    # We need a real executable path for Port.open({:spawn_executable, ...}).
    wrapper = Path.join(System.tmp_dir!(), "fake_sidecar_wrapper.sh")

    File.write!(wrapper, """
    #!/bin/sh
    exec #{elixir_path} #{@fake_sidecar}
    """)

    File.chmod!(wrapper, 0o755)

    # Start the Bridge GenServer with the fake sidecar
    pid =
      start_supervised!({Dust.Bridge, [sidecar_path: wrapper, ts_state_dir: System.tmp_dir!()]})

    # Give the script a moment to boot
    Process.sleep(200)

    {:ok, bridge: pid}
  end

  # ── get_peers/0 ─────────────────────────────────────────────────────────

  describe "get_peers/0" do
    test "parses a comma-separated list of IPs from OK response" do
      assert {:ok, peers} = Dust.Bridge.get_peers()
      assert peers == ["100.64.0.1", "100.64.0.2", "100.64.0.3"]
    end
  end

  # ── proxy/2 ─────────────────────────────────────────────────────────────

  describe "proxy/2" do
    test "parses local port from OK response" do
      assert {:ok, port} = Dust.Bridge.proxy("100.64.0.1", 9000)
      assert port == 54321
      assert is_integer(port)
    end
  end

  # ── expose/1 ────────────────────────────────────────────────────────────

  describe "expose/1" do
    test "returns :ok on success" do
      assert :ok = Dust.Bridge.expose(4369)
    end
  end

  # ── serve_secrets/2 ─────────────────────────────────────────────────────

  describe "serve_secrets/2" do
    test "returns :ok on success" do
      assert :ok = Dust.Bridge.serve_secrets("base64key", "my_cookie")
    end
  end

  # ── create_invite/0 ─────────────────────────────────────────────────────

  describe "create_invite/0" do
    test "returns {:ok, token} where token is a 32-char hex string" do
      assert {:ok, token} = Dust.Bridge.create_invite()
      assert byte_size(token) == 32
      assert Regex.match?(~r/^[0-9a-f]{32}$/, token)
    end
  end

  # ── join/2 ──────────────────────────────────────────────────────────────

  describe "join/2" do
    test "parses master key and OTP cookie from OK response" do
      assert {:ok, master_key_b64, otp_cookie} = Dust.Bridge.join("100.64.0.1", "mytoken")
      assert is_binary(master_key_b64)
      assert otp_cookie == "test_otp_cookie"

      # Verify the master key is valid base64
      assert {:ok, _} = Base.decode64(master_key_b64)
    end
  end

  # ── send_command/2 ──────────────────────────────────────────────────────

  describe "send_command/2" do
    test "returns raw OK response" do
      assert {:ok, "OK:" <> _} = Dust.Bridge.send_command("PEERS")
    end

    test "returns raw ERR response" do
      assert {:ok, "ERR: " <> reason} = Dust.Bridge.send_command("ERR_PEERS")
      assert reason == "network unavailable"
    end
  end
end
