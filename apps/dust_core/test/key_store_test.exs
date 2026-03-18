defmodule Dust.Core.KeyStoreTest do
  use ExUnit.Case, async: false

  alias Dust.Core.KeyStore

  @tmp_dir System.tmp_dir!()
  @test_password "test_password_123"

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

  # ── Locked state on boot ───────────────────────────────────────────────

  describe "locked state on boot" do
    test "starts in :locked state" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)

      assert {:error, :locked} = KeyStore.get_key()
      refute KeyStore.has_key?()
    end

    test "does not create key file on boot" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)

      refute File.exists?(path)
    end
  end

  # ── Unlock ─────────────────────────────────────────────────────────────

  describe "unlock/1" do
    test "generates a key on first unlock when no file exists" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)

      assert :ok = KeyStore.unlock(@test_password)
      assert {:ok, key} = KeyStore.get_key()
      assert byte_size(key) == 32
      assert KeyStore.has_key?()
    end

    test "persists the key to disk on first unlock" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      :ok = KeyStore.unlock(@test_password)

      assert File.exists?(path)
      # Key file: 16 salt + 16 IV + 16 tag + 32 ciphertext = 80 bytes
      {:ok, stat} = File.stat(path)
      assert stat.size == 80
    end

    test "decrypts existing key on unlock after restart" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      :ok = KeyStore.unlock(@test_password)
      {:ok, original_key} = KeyStore.get_key()

      # Restart with same path
      stop_supervised!(KeyStore)
      start_supervised!({KeyStore, [key_path: path]})

      # Must unlock again
      assert {:error, :locked} = KeyStore.get_key()
      :ok = KeyStore.unlock(@test_password)
      {:ok, reloaded_key} = KeyStore.get_key()
      assert reloaded_key == original_key
    end

    test "returns error for wrong password" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      :ok = KeyStore.unlock(@test_password)

      # Restart and try wrong password
      stop_supervised!(KeyStore)
      start_supervised!({KeyStore, [key_path: path]})

      assert {:error, :decrypt_failed} = KeyStore.unlock("wrong_password")
      assert {:error, :locked} = KeyStore.get_key()
    end

    test "returns :already_unlocked when already unlocked" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      :ok = KeyStore.unlock(@test_password)

      assert {:error, :already_unlocked} = KeyStore.unlock(@test_password)
    end
  end

  # ── Lock ───────────────────────────────────────────────────────────────

  describe "lock/0" do
    test "wipes key and transitions to :locked" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      :ok = KeyStore.unlock(@test_password)
      assert {:ok, _key} = KeyStore.get_key()

      :ok = KeyStore.lock()
      assert {:error, :locked} = KeyStore.get_key()
      refute KeyStore.has_key?()
    end

    test "can unlock again after locking" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      :ok = KeyStore.unlock(@test_password)
      {:ok, original_key} = KeyStore.get_key()

      :ok = KeyStore.lock()
      :ok = KeyStore.unlock(@test_password)
      {:ok, restored_key} = KeyStore.get_key()

      assert restored_key == original_key
    end
  end

  # ── set_key (peer sync) ─────────────────────────────────────────────────

  describe "set_key/1" do
    test "rejects when locked" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)

      peer_key = :crypto.strong_rand_bytes(32)
      assert {:error, :locked} = KeyStore.set_key(peer_key)
    end

    test "accepts a 32-byte key and persists it when unlocked" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      :ok = KeyStore.unlock(@test_password)

      peer_key = :crypto.strong_rand_bytes(32)
      assert :ok = KeyStore.set_key(peer_key)
      assert {:ok, ^peer_key} = KeyStore.get_key()
    end

    test "persisted peer key survives restart with correct password" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      :ok = KeyStore.unlock(@test_password)

      peer_key = :crypto.strong_rand_bytes(32)
      :ok = KeyStore.set_key(peer_key)

      stop_supervised!(KeyStore)
      start_supervised!({KeyStore, [key_path: path]})
      :ok = KeyStore.unlock(@test_password)

      assert {:ok, ^peer_key} = KeyStore.get_key()
    end

    test "rejects non-32-byte keys" do
      assert {:error, :invalid_key_size} = KeyStore.set_key(<<1, 2, 3>>)
      assert {:error, :invalid_key_size} = KeyStore.set_key(:crypto.strong_rand_bytes(16))
    end
  end

  # ── has_key? ────────────────────────────────────────────────────────────

  describe "has_key?/0" do
    test "returns false when locked" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      refute KeyStore.has_key?()
    end

    test "returns true after unlock" do
      path = unique_key_path()
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)
      :ok = KeyStore.unlock(@test_password)
      assert KeyStore.has_key?()
    end
  end

  # ── Corrupt file handling ───────────────────────────────────────────────

  describe "corrupt key file" do
    test "returns decrypt_failed for corrupt key file on unlock" do
      path = unique_key_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "this is not a valid key file at all")
      on_exit(fn -> File.rm(path) end)

      start_fresh_key_store(path)

      assert {:error, :decrypt_failed} = KeyStore.unlock(@test_password)
      assert {:error, :locked} = KeyStore.get_key()
    end
  end
end
