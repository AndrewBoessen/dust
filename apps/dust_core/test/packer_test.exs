defmodule Dust.Core.PackerTest do
  use ExUnit.Case, async: false

  alias Dust.Core.Packer
  alias Dust.Core.Crypto.{FileMeta, ChunkMeta}

  @tmp_dir System.tmp_dir!()

  setup do
    if Process.whereis(Dust.Core.Supervisor) do
      Supervisor.terminate_child(Dust.Core.Supervisor, Dust.Core.KeyStore)
      Supervisor.delete_child(Dust.Core.Supervisor, Dust.Core.KeyStore)
    end

    _ = stop_supervised(Dust.Core.KeyStore)

    key_path = Dust.Utilities.File.master_key_file()

    File.rm(key_path)
    start_supervised!({Dust.Core.KeyStore, [key_path: key_path]})
    :ok = Dust.Core.KeyStore.unlock("test_password")
    on_exit(fn -> File.rm(key_path) end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp write_tmp_file(name, content) do
    path = Path.join(@tmp_dir, "dust_test_#{name}_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # ── process_file_stream/1 ───────────────────────────────────────────────

  describe "process_file_stream/1" do
    test "returns {:ok, file_meta, stream} for a regular file" do
      path = write_tmp_file("regular", "test content")

      assert {:ok, %FileMeta{}, stream} = Packer.process_file_stream(path)
      assert is_function(stream, 2) or is_struct(stream, Stream)
    end

    test "file_meta contains a 64-byte encrypted file key" do
      path = write_tmp_file("key_size", "data")

      {:ok, %FileMeta{encrypted_file_key: key}, _stream} = Packer.process_file_stream(path)
      assert byte_size(key) == 64
    end

    test "stream yields {ChunkMeta, binary} tuples" do
      path = write_tmp_file("chunks", "some data for chunking")

      {:ok, _meta, stream} = Packer.process_file_stream(path)
      chunks = Enum.to_list(stream)

      assert length(chunks) >= 1

      Enum.each(chunks, fn {chunk_meta, ciphertext} ->
        assert %ChunkMeta{} = chunk_meta
        assert is_binary(ciphertext)
        assert is_binary(chunk_meta.hash)
        assert chunk_meta.size == byte_size(ciphertext)
        assert chunk_meta.size > 0
      end)
    end

    test "chunk hash is a hex-encoded SHA-256 (64 chars)" do
      path = write_tmp_file("hash_check", "verify hash format")

      {:ok, _meta, stream} = Packer.process_file_stream(path)
      [{chunk_meta, _ciphertext}] = Enum.to_list(stream)

      assert String.length(chunk_meta.hash) == 64
      assert chunk_meta.hash =~ ~r/^[0-9A-F]{64}$/
    end

    test "chunk hash matches HMAC of plaintext with content-hash label" do
      plain = "verify hash integrity"
      path = write_tmp_file("hash_verify", plain)
      {:ok, _meta, stream} = Packer.process_file_stream(path)

      [{chunk_meta, _ciphertext}] = Enum.to_list(stream)

      expected_hash = :crypto.mac(:hmac, :sha256, plain, "content-hash") |> Base.encode16()
      assert chunk_meta.hash == expected_hash
    end

    test "each call generates a different file key (different encrypted_file_key)" do
      path = write_tmp_file("unique_keys", "same content")

      {:ok, meta1, _} = Packer.process_file_stream(path)
      {:ok, meta2, _} = Packer.process_file_stream(path)

      assert meta1.encrypted_file_key != meta2.encrypted_file_key
    end

    test "returns {:error, :enoent} for non-existent file" do
      assert {:error, :enoent} = Packer.process_file_stream("/tmp/nonexistent_dust_test_file")
    end

    test "returns {:error, :eisdir} for a directory" do
      assert {:error, :eisdir} = Packer.process_file_stream(@tmp_dir)
    end

    test "handles empty file" do
      path = write_tmp_file("empty", "")

      {:ok, %FileMeta{}, stream} = Packer.process_file_stream(path)
      chunks = Enum.to_list(stream)

      # Empty file produces no chunks
      assert chunks == []
    end

    test "produces multiple chunks for data exceeding chunk size" do
      # Create content slightly larger than 4MB to get 2 chunks
      content = :crypto.strong_rand_bytes(4 * 1024 * 1024 + 100)
      path = write_tmp_file("multi_chunk", content)

      {:ok, _meta, stream} = Packer.process_file_stream(path)
      chunks = Enum.to_list(stream)

      assert length(chunks) == 2
    end
  end
end
