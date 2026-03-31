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

  @doc """
  Encrypts `plain_binary` with the given 256-bit `key` using AES-256-GCM.

  Returns a single binary: `<<IV::128, Tag::128, Ciphertext::binary>>`.
  A fresh random IV is generated per call.
  """
  @spec encrypt_with_key(binary(), master_key() | file_key() | chunk_key()) :: binary()
  def encrypt_with_key(plain_binary, key) do
    iv = :crypto.strong_rand_bytes(16)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(@aes_mode, key, iv, plain_binary, "", true)

    iv <> tag <> ciphertext
  end

  @doc """
  Decrypts a payload produced by `encrypt_with_key/2`.

  Expects `payload` to be at least 32 bytes (`<<IV::128, Tag::128, ...>>`).
  Returns the plaintext binary on success, or `{:error, :integrity_check_failed}`
  if the key is wrong or the data has been tampered with.
  """
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

  @doc """
  Encrypts `plaintext` using the network-wide master key.

  Convenience wrapper that fetches the master key from
  `Dust.Core.KeyStore` and delegates to `encrypt_with_key/2`.

  Raises if the KeyStore is locked.
  """
  @spec encrypt_with_master(binary()) :: binary()
  def encrypt_with_master(plaintext) do
    encrypt_with_key(plaintext, get_master_key!())
  end

  @doc """
  Decrypts the encrypted file key inside a `FileMeta` struct.

  Uses the master key to unwrap the file key. Returns `{:ok, file_key}` or
  `{:error, :integrity_check_failed}` if the master key is wrong or the
  wrapped key has been tampered with.
  """
  @spec decrypt_file_key(FileMeta.t()) :: {:ok, file_key()} | {:error, :integrity_check_failed}
  def decrypt_file_key(%FileMeta{encrypted_file_key: wrapped_key}) do
    case decrypt_with_key(wrapped_key, get_master_key!()) do
      {:error, _} = err -> err
      key when is_binary(key) -> {:ok, key}
    end
  end

  @spec get_master_key!() :: master_key()
  defp get_master_key! do
    case Dust.Core.KeyStore.get_key() do
      {:ok, key} -> key
      {:error, :locked} -> raise "KeyStore is locked – call Dust.Core.KeyStore.unlock/1 first"
    end
  end
end
