defmodule Dust.Core.Packer do
  @moduledoc """
  Pack files for network storage.

  Streams a file in 4 MB chunks, encrypts each chunk with AES-256-GCM,
  and produces a lazy stream of `{ChunkMeta, ciphertext}` tuples ready
  for network storage.
  """

  alias Dust.Core.Crypto
  alias Dust.Core.Crypto.{FileMeta, ChunkMeta}

  @chunk_size 4 * 1024 * 1024

  @doc """
  Process a file and prepare it for network storage.

  Returns `{:ok, %FileMeta{}, stream}` where the stream lazily yields
  `{%ChunkMeta{}, encrypted_binary}` tuples, or `{:error, reason}` on failure.

  Steps:
  1. Validates the file path before building the stream.
  2. Streams the file in #{@chunk_size |> div(1024 * 1024)} MB chunks.
  3. Encrypts each chunk using AES-256-GCM with a unique key and IV.
  4. Generates a SHA-256 metadata hash for each encrypted chunk.
  """
  @spec process_file_stream(Path.t()) ::
          {:ok, FileMeta.t(), Enumerable.t({ChunkMeta.t(), binary()})} | {:error, File.posix()}
  def process_file_stream(path) do
    case File.stat(path) do
      {:error, reason} ->
        {:error, reason}

      {:ok, %File.Stat{type: :directory}} ->
        {:error, :eisdir}

      {:ok, %File.Stat{type: :regular}} ->
        file_key = :crypto.strong_rand_bytes(32)
        wrapped_file_key = Crypto.encrypt_with_master(file_key)
        file_meta = %FileMeta{encrypted_file_key: wrapped_file_key}

        stream =
          path
          |> File.stream!(@chunk_size)
          |> Stream.map(fn plain_chunk -> process_chunk(plain_chunk, file_key) end)

        {:ok, file_meta, stream}

      {:ok, %File.Stat{}} ->
        {:error, :einval}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec process_chunk(binary(), Crypto.file_key()) :: {ChunkMeta.t(), binary()}
  defp process_chunk(plain_binary, file_key) do
    chunk_key = :crypto.hash(:sha256, plain_binary)
    wrapped_chunk_key = Crypto.encrypt_with_key(chunk_key, file_key)

    encrypted_payload = Crypto.encrypt_with_key(plain_binary, chunk_key)

    meta = generate_chunk_metadata(encrypted_payload, wrapped_chunk_key)
    {meta, encrypted_payload}
  end

  @spec generate_chunk_metadata(binary(), Crypto.encrypted_key()) :: ChunkMeta.t()
  defp generate_chunk_metadata(encrypted_binary, wrapped_chunk_key) do
    hash = :crypto.hash(:sha256, encrypted_binary) |> Base.encode16()

    %ChunkMeta{
      hash: hash,
      size: byte_size(encrypted_binary),
      encrypted_chunk_key: wrapped_chunk_key
    }
  end
end
