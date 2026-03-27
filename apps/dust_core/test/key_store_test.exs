defmodule Dust.Core.KeyStoreTest do
  use ExUnit.Case, async: false

  alias Dust.Core.KeyStore

  @test_password "test_password_123"

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp start_key_store!() do
    data_dir = Application.get_env(:dust_utilities, :persist_dir)
    key_path = Path.join(data_dir, "master.key")

    start_supervised!({KeyStore, [key_path: key_path]})
  end

  defp clean_data_dir! do
    data_dir = Application.get_env(:dust_utilities, :persist_dir)
    key_path = Path.join(data_dir, "master.key")
    File.rm(key_path)
  end

  setup do
    clean_data_dir!()
    start_key_store!()
    on_exit(fn -> clean_data_dir!() end)
  end

  # ── Locked state on boot ───────────────────────────────────────────────

  describe "locked state on boot" do
    test "starts in :locked state" do
      assert {:error, :locked} = KeyStore.get_key()
      refute KeyStore.has_key?()
    end

    test "does not create key file on boot" do
      data_dir = Application.get_env(:dust_utilities, :persist_dir)
      key_path = Path.join(data_dir, "master.key")

      refute File.exists?(key_path)
    end
  end

  # ── Unlock ─────────────────────────────────────────────────────────────

  describe "unlock/1" do
    test "generates a key on first unlock when no file exists" do
      assert :ok = KeyStore.unlock(@test_password)
      assert {:ok, key} = KeyStore.get_key()
      assert byte_size(key) == 32
      assert KeyStore.has_key?()
    end

    test "persists the key to disk on first unlock" do
      data_dir = Application.get_env(:dust_utilities, :persist_dir)
      key_path = Path.join(data_dir, "master.key")

      :ok = KeyStore.unlock(@test_password)

      assert File.exists?(key_path)
      # Key file: 16 salt + 16 IV + 16 tag + 32 ciphertext = 80 bytes
      {:ok, stat} = File.stat(key_path)
      assert stat.size == 80
    end

    test "decrypts existing key on unlock after restart" do
      :ok = KeyStore.unlock(@test_password)
      {:ok, original_key} = KeyStore.get_key()

      data_dir = Application.get_env(:dust_utilities, :persist_dir)
      key_path = Path.join(data_dir, "master.key")

      # Restart with same path
      stop_supervised!(KeyStore)
      start_supervised!({KeyStore, [key_path: key_path]})

      # Must unlock again
      assert {:error, :locked} = KeyStore.get_key()
      :ok = KeyStore.unlock(@test_password)
      {:ok, reloaded_key} = KeyStore.get_key()
      assert reloaded_key == original_key
    end

    test "returns error for wrong password" do
      :ok = KeyStore.unlock(@test_password)

      data_dir = Application.get_env(:dust_utilities, :persist_dir)
      key_path = Path.join(data_dir, "master.key")

      # Restart and try wrong password
      stop_supervised!(KeyStore)
      start_supervised!({KeyStore, [key_path: key_path]})

      assert {:error, :decrypt_failed} = KeyStore.unlock("wrong_password")
      assert {:error, :locked} = KeyStore.get_key()
    end

    test "returns :already_unlocked when already unlocked" do
      :ok = KeyStore.unlock(@test_password)

      assert {:error, :already_unlocked} = KeyStore.unlock(@test_password)
    end
  end

  # ── Lock ───────────────────────────────────────────────────────────────

  describe "lock/0" do
    test "wipes key and transitions to :locked" do
      :ok = KeyStore.unlock(@test_password)
      assert {:ok, _key} = KeyStore.get_key()

      :ok = KeyStore.lock()
      assert {:error, :locked} = KeyStore.get_key()
      refute KeyStore.has_key?()
    end

    test "can unlock again after locking" do
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
      peer_key = :crypto.strong_rand_bytes(32)
      assert {:error, :locked} = KeyStore.set_key(peer_key)
    end

    test "accepts a 32-byte key and persists it when unlocked" do
      :ok = KeyStore.unlock(@test_password)

      peer_key = :crypto.strong_rand_bytes(32)
      assert :ok = KeyStore.set_key(peer_key)
      assert {:ok, ^peer_key} = KeyStore.get_key()
    end

    test "persisted peer key survives restart with correct password" do
      :ok = KeyStore.unlock(@test_password)

      peer_key = :crypto.strong_rand_bytes(32)
      :ok = KeyStore.set_key(peer_key)

      data_dir = Application.get_env(:dust_utilities, :persist_dir)
      key_path = Path.join(data_dir, "master.key")

      stop_supervised!(KeyStore)
      start_supervised!({KeyStore, [key_path: key_path]})
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
      refute KeyStore.has_key?()
    end

    test "returns true after unlock" do
      :ok = KeyStore.unlock(@test_password)
      assert KeyStore.has_key?()
    end
  end

  # ── Corrupt file handling ───────────────────────────────────────────────

  describe "corrupt key file" do
    test "returns decrypt_failed for corrupt key file on unlock" do
      data_dir = Application.get_env(:dust_utilities, :persist_dir)
      key_path = Path.join(data_dir, "master.key")

      File.write!(key_path, "this is not a valid key file at all")

      assert {:error, :decrypt_failed} = KeyStore.unlock(@test_password)
      assert {:error, :locked} = KeyStore.get_key()
    end
  end
end
