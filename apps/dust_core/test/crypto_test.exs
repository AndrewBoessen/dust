defmodule Dust.Core.CryptoTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Dust.Core.Crypto
  alias Dust.Core.Crypto.{FileMeta, ChunkMeta}

  # ── Struct enforcement ──────────────────────────────────────────────────

  describe "FileMeta" do
    test "enforces :encrypted_file_key" do
      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        struct!(FileMeta, %{})
      end
    end

    test "constructs with required key" do
      meta = %FileMeta{encrypted_file_key: <<0::512>>}
      assert meta.encrypted_file_key == <<0::512>>
    end
  end

  describe "ChunkMeta" do
    test "enforces all keys" do
      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        struct!(ChunkMeta, %{})
      end
    end

    test "constructs with all required keys" do
      meta = %ChunkMeta{
        hash: "ABCDEF",
        size: 1024,
        encrypted_chunk_key: <<0::512>>
      }

      assert meta.hash == "ABCDEF"
      assert meta.size == 1024
    end
  end

  # ── encrypt_with_key / decrypt_with_key ─────────────────────────────────

  describe "encrypt_with_key/2 and decrypt_with_key/2" do
    test "round-trips arbitrary plaintext" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "hello, world!"

      ciphertext = Crypto.encrypt_with_key(plaintext, key)
      assert Crypto.decrypt_with_key(ciphertext, key) == plaintext
    end

    test "round-trips empty binary" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = ""

      ciphertext = Crypto.encrypt_with_key(plaintext, key)
      assert Crypto.decrypt_with_key(ciphertext, key) == plaintext
    end

    test "round-trips large binary" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = :crypto.strong_rand_bytes(8 * 1024 * 1024)

      ciphertext = Crypto.encrypt_with_key(plaintext, key)
      assert Crypto.decrypt_with_key(ciphertext, key) == plaintext
    end

    test "ciphertext is at least 32 bytes larger than plaintext (IV + tag)" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "test"

      ciphertext = Crypto.encrypt_with_key(plaintext, key)
      # 16-byte IV + 16-byte tag + ciphertext
      assert byte_size(ciphertext) == byte_size(plaintext) + 32
    end

    test "each encryption produces different ciphertext (unique IVs)" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "deterministic input"

      ct1 = Crypto.encrypt_with_key(plaintext, key)
      ct2 = Crypto.encrypt_with_key(plaintext, key)
      assert ct1 != ct2
    end

    test "decryption with wrong key returns error" do
      key = :crypto.strong_rand_bytes(32)
      wrong_key = :crypto.strong_rand_bytes(32)
      ciphertext = Crypto.encrypt_with_key("secret", key)

      assert {:error, :integrity_check_failed} = Crypto.decrypt_with_key(ciphertext, wrong_key)
    end

    test "decryption of tampered ciphertext returns error" do
      key = :crypto.strong_rand_bytes(32)
      ciphertext = Crypto.encrypt_with_key("secret", key)

      # Flip a byte in the ciphertext portion (after IV + tag)
      <<head::binary-33, byte::8, rest::binary>> = ciphertext
      tampered = head <> <<Bitwise.bxor(byte, 0xFF)>> <> rest

      assert {:error, :integrity_check_failed} = Crypto.decrypt_with_key(tampered, key)
    end

    test "decryption of truncated payload returns error" do
      key = :crypto.strong_rand_bytes(32)
      assert {:error, :integrity_check_failed} = Crypto.decrypt_with_key(<<0::8>>, key)
    end

    test "decryption of empty binary returns error" do
      key = :crypto.strong_rand_bytes(32)
      assert {:error, :integrity_check_failed} = Crypto.decrypt_with_key(<<>>, key)
    end
  end

  # ── Master-key helpers ──────────────────────────────────────────────────

  describe "encrypt_with_master/1 and decrypt_file_key/1" do
    setup %{tmp_dir: tmp_dir} do
      old_env = Application.get_env(:dust_utilities, :persist_dir)
      Application.put_env(:dust_utilities, :persist_dir, tmp_dir)

      # Ensure a fresh, unlocked KeyStore for master-key tests
      if Process.whereis(Dust.Core.Supervisor) do
        Supervisor.terminate_child(Dust.Core.Supervisor, Dust.Core.KeyStore)
        Supervisor.delete_child(Dust.Core.Supervisor, Dust.Core.KeyStore)
      end

      _ = stop_supervised(Dust.Core.KeyStore)

      start_supervised!(Dust.Core.KeyStore)
      :ok = Dust.Core.KeyStore.unlock("test_password")

      on_exit(fn ->
        if old_env do
          Application.put_env(:dust_utilities, :persist_dir, old_env)
        else
          Application.delete_env(:dust_utilities, :persist_dir)
        end
      end)

      :ok
    end

    test "round-trips a file key through master encryption" do
      file_key = :crypto.strong_rand_bytes(32)

      wrapped = Crypto.encrypt_with_master(file_key)
      file_meta = %FileMeta{encrypted_file_key: wrapped}

      assert {:ok, ^file_key} = Crypto.decrypt_file_key(file_meta)
    end

    test "wrapped key has expected size (IV + tag + 32-byte key)" do
      file_key = :crypto.strong_rand_bytes(32)
      wrapped = Crypto.encrypt_with_master(file_key)

      # 16 IV + 16 tag + 32 ciphertext = 64
      assert byte_size(wrapped) == 64
    end
  end
end
