defmodule Dust.Core.UnpackerTest do
  use ExUnit.Case, async: true

  alias Dust.Core.Crypto
  alias Dust.Core.Packer
  alias Dust.Core.Unpacker

  @tmp_dir System.tmp_dir!()

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp write_tmp_file(name, content) do
    path = Path.join(@tmp_dir, "dust_test_#{name}_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp pack_and_get_key(content) do
    path = write_tmp_file("unpack", content)
    {:ok, file_meta, stream} = Packer.process_file_stream(path)
    file_key = Crypto.decrypt_file_key(file_meta)
    chunks = Enum.to_list(stream)
    {file_key, chunks}
  end

  # ── unpack_chunk/3 ──────────────────────────────────────────────────────

  describe "unpack_chunk/3" do
    test "decrypts a single chunk back to plaintext" do
      original = "hello, this is test data"
      {file_key, [{meta, ciphertext}]} = pack_and_get_key(original)

      assert {:ok, ^original} = Unpacker.unpack_chunk(ciphertext, meta, file_key)
    end

    test "decrypts each chunk of a multi-chunk file" do
      original = :crypto.strong_rand_bytes(4 * 1024 * 1024 + 500)
      {file_key, chunks} = pack_and_get_key(original)

      assert length(chunks) == 2

      reassembled =
        chunks
        |> Enum.map(fn {meta, ciphertext} ->
          {:ok, plaintext} = Unpacker.unpack_chunk(ciphertext, meta, file_key)
          plaintext
        end)
        |> IO.iodata_to_binary()

      assert reassembled == original
    end

    test "returns {:error, :invalid_file_key} with wrong file key" do
      original = "secret data"
      {_file_key, [{meta, ciphertext}]} = pack_and_get_key(original)

      wrong_key = :crypto.strong_rand_bytes(32)
      assert {:error, :invalid_file_key} = Unpacker.unpack_chunk(ciphertext, meta, wrong_key)
    end

    test "returns {:error, :integrity_check_failed} with tampered ciphertext" do
      original = "important data"
      {file_key, [{meta, ciphertext}]} = pack_and_get_key(original)

      # Flip a byte in the encrypted payload
      <<head::binary-33, byte::8, rest::binary>> = ciphertext
      tampered = head <> <<Bitwise.bxor(byte, 0xFF)>> <> rest

      assert {:error, :integrity_check_failed} = Unpacker.unpack_chunk(tampered, meta, file_key)
    end

    test "returns error with tampered encrypted_chunk_key in meta" do
      original = "test"
      {file_key, [{meta, ciphertext}]} = pack_and_get_key(original)

      # Corrupt the encrypted_chunk_key
      <<head::binary-33, byte::8, rest::binary>> = meta.encrypted_chunk_key
      tampered_key = head <> <<Bitwise.bxor(byte, 0xFF)>> <> rest
      bad_meta = %{meta | encrypted_chunk_key: tampered_key}

      result = Unpacker.unpack_chunk(ciphertext, bad_meta, file_key)
      assert {:error, _reason} = result
    end
  end

  # ── Full round-trip integration ─────────────────────────────────────────

  describe "full round-trip: pack → decrypt_file_key → unpack" do
    test "recovers original content of a small file" do
      original = "The quick brown fox jumps over the lazy dog."
      path = write_tmp_file("roundtrip_small", original)

      {:ok, file_meta, stream} = Packer.process_file_stream(path)
      file_key = Crypto.decrypt_file_key(file_meta)

      reassembled =
        stream
        |> Enum.map(fn {meta, ct} ->
          {:ok, pt} = Unpacker.unpack_chunk(ct, meta, file_key)
          pt
        end)
        |> IO.iodata_to_binary()

      assert reassembled == original
    end

    test "recovers original content of a large multi-chunk file" do
      original = :crypto.strong_rand_bytes(10 * 1024 * 1024)
      path = write_tmp_file("roundtrip_large", original)

      {:ok, file_meta, stream} = Packer.process_file_stream(path)
      file_key = Crypto.decrypt_file_key(file_meta)

      reassembled =
        stream
        |> Enum.map(fn {meta, ct} ->
          {:ok, pt} = Unpacker.unpack_chunk(ct, meta, file_key)
          pt
        end)
        |> IO.iodata_to_binary()

      assert reassembled == original
    end

    test "recovers original content of a file exactly 4MB (one full chunk)" do
      original = :crypto.strong_rand_bytes(4 * 1024 * 1024)
      path = write_tmp_file("roundtrip_exact", original)

      {:ok, file_meta, stream} = Packer.process_file_stream(path)
      file_key = Crypto.decrypt_file_key(file_meta)

      chunks = Enum.to_list(stream)
      assert length(chunks) == 1

      [{meta, ct}] = chunks
      assert {:ok, ^original} = Unpacker.unpack_chunk(ct, meta, file_key)
    end
  end
end
