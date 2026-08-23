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

  describe "join/1" do
    setup do
      secrets_path = Dust.Utilities.File.secrets_file()
      File.rm(secrets_path)

      # A node holding its own master key and no data — the state a fresh
      # node is in when it joins an existing network.
      _ = KeyStore.lock()
      Dust.Bridge.Secrets.clear_fetched_master_key()
      File.rm(Dust.Utilities.File.master_key_file())
      :ok = KeyStore.unlock("join_handler_password")

      # The umbrella shares one persist_dir, so storage and the mesh may
      # still hold data written by an earlier app's suite.
      for {chunk_hash, index} <- Dust.Storage.list_local_shard_keys() do
        Dust.Storage.delete_shard(chunk_hash, index)
      end

      for {id, _entry} <- Dust.Mesh.FileSystem.FileMap.all() do
        Dust.Mesh.FileSystem.FileMap.delete(id)
      end

      on_exit(fn ->
        File.rm(secrets_path)
        KeyStore.lock()
      end)

      {:ok, secrets_path: secrets_path}
    end

    defp join_conn(params) do
      conn(:post, "/api/v1/join")
      |> Map.put(:body_params, params)
      |> ClusterHandler.join()
    end

    test "adopts the peer's cookie and master key", %{secrets_path: secrets_path} do
      network_key = :crypto.strong_rand_bytes(32)

      expect(Dust.Bridge.Mock, :join, fn "100.64.0.7", "invite-token" ->
        {:ok, Base.encode64(network_key), "peer-cookie-abc123"}
      end)

      conn = join_conn(%{"peer_address" => "100.64.0.7", "token" => "invite-token"})

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "joined"
      assert body["master_key"] == "adopted"

      # Retrieving the secrets is not enough — a node that does not adopt
      # the peer's cookie keeps its own and is rejected by every peer with
      # "Invalid challenge reply".
      assert File.read!(secrets_path) == "peer-cookie-abc123"
      assert {:ok, ^network_key} = KeyStore.get_key()
    end

    test "returns 409 with the local data counts when the node holds data" do
      :ok = Dust.Storage.put_shard("handlerjointest", 0, "encrypted-payload")
      on_exit(fn -> Dust.Storage.delete_shard("handlerjointest", 0) end)

      expect(Dust.Bridge.Mock, :join, fn _peer, _token ->
        {:ok, Base.encode64(:crypto.strong_rand_bytes(32)), "peer-cookie-abc123"}
      end)

      conn = join_conn(%{"peer_address" => "100.64.0.7", "token" => "invite-token"})

      assert conn.status == 409
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "local_data_exists"
      assert body["local_data"]["shards"] == 1
    end

    test "adopts anyway when force is set", %{secrets_path: secrets_path} do
      :ok = Dust.Storage.put_shard("handlerjointest", 0, "encrypted-payload")
      on_exit(fn -> Dust.Storage.delete_shard("handlerjointest", 0) end)

      network_key = :crypto.strong_rand_bytes(32)

      expect(Dust.Bridge.Mock, :join, fn _peer, _token ->
        {:ok, Base.encode64(network_key), "peer-cookie-abc123"}
      end)

      conn =
        join_conn(%{
          "peer_address" => "100.64.0.7",
          "token" => "invite-token",
          "force" => true
        })

      assert conn.status == 200
      assert File.read!(secrets_path) == "peer-cookie-abc123"
      assert {:ok, ^network_key} = KeyStore.get_key()
    end

    test "reports the bridge error when the join itself fails" do
      expect(Dust.Bridge.Mock, :join, fn _, _ -> {:error, :invalid_token} end)

      conn = join_conn(%{"peer_address" => "100.64.0.7", "token" => "bad"})

      assert conn.status == 400
    end
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
