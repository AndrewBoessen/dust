defmodule Dust.Core.Unpacker do
  @moduledoc """
  Unpack (decrypt) chunks retrieved from the network back into plaintext.
  """

  alias Dust.Core.Crypto
  alias Dust.Core.Crypto.ChunkMeta

  @doc """
  Decrypt an encrypted chunk back to plaintext.

  Requires the raw ciphertext payload, its `ChunkMeta`, and the
  decrypted file key (obtained via `Dust.Core.Crypto.decrypt_file_key/1`).

  Returns `{:ok, plaintext}` on success, or `{:error, reason}` if the
  file key is wrong or the payload has been tampered with.
  """
  @spec unpack_chunk(binary(), ChunkMeta.t(), Crypto.file_key()) ::
          {:ok, binary()} | {:error, atom()}
  def unpack_chunk(ciphertext_payload, %ChunkMeta{} = meta, file_key) do
    case Crypto.decrypt_with_key(meta.encrypted_chunk_key, file_key) do
      {:error, _} ->
        {:error, :invalid_file_key}

      chunk_key when is_binary(chunk_key) ->
        case Crypto.decrypt_with_key(ciphertext_payload, chunk_key) do
          {:error, _} -> {:error, :integrity_check_failed}
          plaintext -> {:ok, plaintext}
        end
    end
  end
end
