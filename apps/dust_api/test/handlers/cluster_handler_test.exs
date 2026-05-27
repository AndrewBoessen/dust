defmodule Dust.Api.Handlers.ClusterHandlerTest do
  use ExUnit.Case, async: false

  import Mox
  import Plug.Test

  alias Dust.Api.Handlers.ClusterHandler
  alias Dust.Core.KeyStore

  setup :set_mox_from_context
  setup :verify_on_exit!

  # Stub the bridge calls KeyStore makes when transitioning between locked
  # and ready — these run inside the KeyStore GenServer process, not the
  # test process, so they need to be stubs (which apply globally) rather
  # than expectations.
  setup do
    Mox.set_mox_global()
    stub(Dust.Bridge.Mock, :serve_secrets, fn _, _ -> :ok end)
    stub(Dust.Bridge.Mock, :stop_serving_secrets, fn -> :ok end)
    :ok
  end

  describe "create_invite/1 when keystore is unlocked" do
    setup do
      # The umbrella's global persist_dir is shared across apps' test suites,
      # so a prior run may have left a master.key encrypted with a different
      # password. Reset state before unlocking with our test password.
      _ = KeyStore.lock()
      File.rm(Dust.Utilities.File.master_key_file())
      :ok = KeyStore.unlock("test_password")
      on_exit(fn -> KeyStore.lock() end)
      :ok
    end

    test "returns 201 with the sidecar's Tailscale self_ip as join_ip" do
      expect(Dust.Bridge.Mock, :auth_status, fn ->
        {:ok, %{state: "authenticated", self_ip: "100.64.0.5", auth_url: ""}}
      end)

      expect(Dust.Bridge.Mock, :create_invite, fn -> {:ok, "deadbeef"} end)

      conn =
        conn(:post, "/api/v1/invite")
        |> ClusterHandler.create_invite()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["join_ip"] == "100.64.0.5"
      assert body["token"] == "deadbeef"
    end

    test "returns 503 when the node has no Tailscale IP yet" do
      expect(Dust.Bridge.Mock, :auth_status, fn ->
        {:ok, %{state: "needs_login", self_ip: "", auth_url: "https://login.tailscale.com/x"}}
      end)

      conn =
        conn(:post, "/api/v1/invite")
        |> ClusterHandler.create_invite()

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "tailscale_not_ready"
    end

    test "returns 500 when auth_status fails" do
      expect(Dust.Bridge.Mock, :auth_status, fn -> {:error, :timeout} end)

      conn =
        conn(:post, "/api/v1/invite")
        |> ClusterHandler.create_invite()

      assert conn.status == 500
    end
  end

  describe "create_invite/1 when keystore is locked" do
    setup do
      # KeyStore is locked by default; make sure no other test left it open.
      :ok = KeyStore.lock()
      :ok
    end

    test "returns 423 and does not touch the bridge" do
      # No expectations on Bridge.Mock — calling auth_status or create_invite
      # would fail verify_on_exit!.
      conn =
        conn(:post, "/api/v1/invite")
        |> ClusterHandler.create_invite()

      assert conn.status == 423
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "keystore_locked"
    end
  end
end
