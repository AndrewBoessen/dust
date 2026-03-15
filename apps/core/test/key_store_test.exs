defmodule Dust.Core.KeyStoreTest do
  use ExUnit.Case, async: false

  alias Dust.Core.KeyStore

  @tmp_dir System.tmp_dir!()

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp unique_key_path do
    Path.join(@tmp_dir, "dust_test_master_#{System.unique_integer([:positive])}.key")
  end

  defp stop_app_key_store do
    # The :core application starts KeyStore under Dust.Core.Supervisor.
    # We must fully remove it from that supervisor before starting our own.
    if Process.whereis(Dust.Core.Supervisor) do
      Supervisor.terminate_child(Dust.Core.Supervisor, KeyStore)
      Supervisor.delete_child(Dust.Core.Supervisor, KeyStore)
    end

    # Also clean up any ExUnit-supervised instance from a previous test
    _ = stop_supervised(KeyStore)
  end

  defp start_fresh_key_store(path) do
    stop_app_key_store()
    start_supervised!({KeyStore, [key_path: path]})
  end

  # ── Generation & persistence ────────────────────────────────────────────

  describe "first-node key generation" do
    test "generates a key when no file exists" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)

      assert {:ok, key} = KeyStore.get_key()
      assert byte_size(key) == 32
      assert KeyStore.has_key?()
    end

    test "persists the key to disk" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)

      assert File.exists?(path)
      # Key file: 16 salt + 16 IV + 16 tag + 32 ciphertext = 80 bytes
      {:ok, stat} = File.stat(path)
      assert stat.size == 80
    end

    test "reading the key back yields the same value after restart" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      {:ok, original_key} = KeyStore.get_key()

      # Restart with same path
      stop_supervised!(KeyStore)
      start_supervised!({KeyStore, [key_path: path]})

      {:ok, reloaded_key} = KeyStore.get_key()
      assert reloaded_key == original_key
    end
  end

  # ── set_key (peer sync) ─────────────────────────────────────────────────

  describe "set_key/1" do
    test "accepts a 32-byte key and persists it" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)

      peer_key = :crypto.strong_rand_bytes(32)
      assert :ok = KeyStore.set_key(peer_key)
      assert {:ok, ^peer_key} = KeyStore.get_key()
    end

    test "persisted peer key survives restart" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)

      peer_key = :crypto.strong_rand_bytes(32)
      :ok = KeyStore.set_key(peer_key)

      stop_supervised!(KeyStore)
      start_supervised!({KeyStore, [key_path: path]})

      assert {:ok, ^peer_key} = KeyStore.get_key()
    end

    test "rejects non-32-byte keys" do
      assert {:error, :invalid_key_size} = KeyStore.set_key(<<1, 2, 3>>)
      assert {:error, :invalid_key_size} = KeyStore.set_key(:crypto.strong_rand_bytes(16))
    end
  end

  # ── has_key? ────────────────────────────────────────────────────────────

  describe "has_key?/0" do
    test "returns true after key generation" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      assert KeyStore.has_key?()
    end
  end

  # ── Corrupt file handling ───────────────────────────────────────────────

  describe "corrupt key file" do
    test "fails to start with a corrupt key file" do
      path = unique_key_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "this is not a valid key file at all")
      on_exit(fn -> File.rm(path) end)

      stop_app_key_store()

      # init/1 returns {:stop, reason} which surfaces as an exit.
      Process.flag(:trap_exit, true)

      assert {:error, {:key_file_error, :corrupt_key_file}} =
               KeyStore.start_link(key_path: path)
    end
  end
end
