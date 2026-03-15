defmodule Dust.Core.Crypto do
  @moduledoc """
  Shared cryptographic types, data structures, and primitives for the Dust network.

  Provides AES-256-GCM encryption/decryption and the canonical definitions of
  `FileMeta` and `ChunkMeta` structs used across ingestion and materialization.
  """

  @aes_mode :aes_256_gcm

  # ── Types ──────────────────────────────────────────────────────────────

  @typedoc """
  A 256-bit (32-byte) raw cryptographic key.
  Used for Master Keys, File Keys, and derived Chunk Keys.
  """
  @type master_key :: <<_::256>>
  @type file_key :: <<_::256>>
  @type chunk_key :: <<_::256>>

  @typedoc """
  A wrapped 32-byte key encrypted via AES-256-GCM.
  Structure: 16-byte IV + 16-byte Tag + 32-byte Ciphertext = 64 bytes (512 bits).
  """
  @type encrypted_key :: <<_::512>>

  # ── Structs ────────────────────────────────────────────────────────────

  defmodule FileMeta do
    @moduledoc "Metadata for an ingested file, containing its encrypted file key."

    @type t :: %__MODULE__{
            encrypted_file_key: Dust.Core.Crypto.encrypted_key()
          }
    @enforce_keys [:encrypted_file_key]
    defstruct [:encrypted_file_key]
  end

  defmodule ChunkMeta do
    @moduledoc "Metadata for a single encrypted chunk."

    @type t :: %__MODULE__{
            hash: String.t(),
            size: non_neg_integer(),
            encrypted_chunk_key: Dust.Core.Crypto.encrypted_key()
          }
    @enforce_keys [:hash, :size, :encrypted_chunk_key]
    defstruct [:hash, :size, :encrypted_chunk_key]
  end

  # ── Encryption / Decryption ────────────────────────────────────────────

  @spec encrypt_with_key(binary(), master_key() | file_key() | chunk_key()) :: binary()
  def encrypt_with_key(plain_binary, key) do
    iv = :crypto.strong_rand_bytes(16)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(@aes_mode, key, iv, plain_binary, "", true)

    iv <> tag <> ciphertext
  end

  @spec decrypt_with_key(binary(), master_key() | file_key() | chunk_key()) ::
          binary() | {:error, :integrity_check_failed}
  def decrypt_with_key(payload, key) when byte_size(payload) >= 32 do
    <<iv::binary-16, tag::binary-16, ciphertext::binary>> = payload

    case :crypto.crypto_one_time_aead(@aes_mode, key, iv, ciphertext, "", tag, false) do
      :error -> {:error, :integrity_check_failed}
      plaintext -> plaintext
    end
  end

  def decrypt_with_key(_payload, _key), do: {:error, :integrity_check_failed}

  # ── Master-key helpers ─────────────────────────────────────────────────

  @spec encrypt_with_master(binary()) :: binary()
  def encrypt_with_master(plaintext) do
    encrypt_with_key(plaintext, get_master_key())
  end

  @spec decrypt_file_key(FileMeta.t()) :: file_key() | {:error, :integrity_check_failed}
  def decrypt_file_key(%FileMeta{encrypted_file_key: wrapped_key}) do
    decrypt_with_key(wrapped_key, get_master_key())
  end

  @spec get_master_key() :: master_key()
  defp get_master_key do
    case Dust.Core.KeyStore.get_key() do
      {:ok, key} -> key
      {:error, :not_initialized} -> raise "Master key not yet initialized"
    end
  end
end
