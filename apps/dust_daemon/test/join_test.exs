defmodule Dust.Daemon.JoinTest do
  use ExUnit.Case, async: false

  import Mox

  alias Dust.Core.KeyStore
  alias Dust.Daemon.Join
  alias Dust.Mesh.FileSystem.FileMap

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    Mox.set_mox_global()
    stub(Dust.Bridge.Mock, :serve_secrets, fn _, _ -> :ok end)
    stub(Dust.Bridge.Mock, :stop_serving_secrets, fn -> :ok end)

    secrets_path = Dust.Utilities.File.secrets_file()
    File.rm(secrets_path)
    clear_local_data()

    # Start each test from a node holding its own master key: drop any key
    # cached by a previous join so unlock/1 mints a fresh one rather than
    # adopting the last test's peer key.
    _ = KeyStore.lock()
    Dust.Bridge.Secrets.clear_fetched_master_key()
    File.rm(Dust.Utilities.File.master_key_file())
    :ok = KeyStore.unlock("join_test_password")

    on_exit(fn ->
      File.rm(secrets_path)
      clear_local_data()
    end)

    {:ok, secrets_path: secrets_path}
  end

  defp clear_local_data do
    for {chunk_hash, index} <- Dust.Storage.list_local_shard_keys() do
      Dust.Storage.delete_shard(chunk_hash, index)
    end

    for {id, _entry} <- FileMap.all() do
      FileMap.delete(id)
    end

    :ok
  end

  defp expect_peer_secrets(master_key, cookie \\ "network-cookie") do
    expect(Dust.Bridge.Mock, :join, fn _peer, _token ->
      {:ok, Base.encode64(master_key), cookie}
    end)
  end

  describe "join/3 on a node holding no data" do
    test "adopts the network's cookie and master key", %{secrets_path: secrets_path} do
      network_key = :crypto.strong_rand_bytes(32)
      expect_peer_secrets(network_key)

      assert {:ok, :adopted} = Join.join("100.64.0.2", "invite-token")

      assert File.read!(secrets_path) == "network-cookie"
      assert {:ok, ^network_key} = KeyStore.get_key()
    end

    test "is a no-op when the node already holds the network's key" do
      {:ok, current_key} = KeyStore.get_key()
      expect_peer_secrets(current_key)

      assert {:ok, :already_current} = Join.join("100.64.0.2", "invite-token")
      assert {:ok, ^current_key} = KeyStore.get_key()
    end
  end

  describe "join/3 on a node that already holds data" do
    setup do
      :ok = Dust.Storage.put_shard("jointestchunk", 0, "encrypted-payload")
      :ok
    end

    test "refuses to replace the master key and changes nothing", %{secrets_path: secrets_path} do
      {:ok, key_before} = KeyStore.get_key()
      network_key = :crypto.strong_rand_bytes(32)
      expect_peer_secrets(network_key)

      assert {:error, :local_data_exists, counts} = Join.join("100.64.0.2", "invite-token")
      assert counts.shards == 1

      # A refused join must leave the node exactly as it was — no cookie
      # adopted either, so it cannot end up half-joined.
      refute File.exists?(secrets_path)
      assert {:ok, ^key_before} = KeyStore.get_key()
    end

    test "replaces the master key when forced", %{secrets_path: secrets_path} do
      network_key = :crypto.strong_rand_bytes(32)
      expect_peer_secrets(network_key)

      assert {:ok, :adopted} = Join.join("100.64.0.2", "invite-token", force: true)

      assert File.read!(secrets_path) == "network-cookie"
      assert {:ok, ^network_key} = KeyStore.get_key()
    end
  end

  describe "join/3 failures" do
    test "passes through a bridge error" do
      expect(Dust.Bridge.Mock, :join, fn _peer, _token -> {:error, :invalid_token} end)

      assert {:error, :invalid_token} = Join.join("100.64.0.2", "bad-token")
    end

    test "rejects a master key that is not a valid 256-bit key" do
      expect(Dust.Bridge.Mock, :join, fn _peer, _token ->
        {:ok, Base.encode64(<<1, 2, 3>>), "network-cookie"}
      end)

      assert {:error, :invalid_key_size} = Join.join("100.64.0.2", "invite-token")
    end
  end
end
