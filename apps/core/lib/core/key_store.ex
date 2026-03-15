defmodule Dust.Core.KeyStore do
  @moduledoc """
  Manages the network-wide master key lifecycle.

  On startup the GenServer checks for a persisted key file on disk:

    * **Key file exists** – reads, decrypts-at-rest, and loads it into state.
    * **Key file missing, no peers** – generates a fresh 32-byte key, persists it.
    * **Key file missing, peers available** – enters `:awaiting_key` and waits
      for the mesh layer to call `set_key/1` with the key obtained from a peer.

  The key is encrypted at rest using a device-bound key derived from the
  machine-id via PBKDF2 so that simply copying the file to another machine
  does not expose the master key.
  """

  use GenServer

  require Logger

  @key_size 32
  @salt_size 16
  @pbkdf2_iterations 100_000
  @aes_mode :aes_256_gcm

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Start the KeyStore GenServer under a supervisor."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Retrieve the master key.

  Returns `{:ok, <<key::256>>}` when the key is loaded,
  or `{:error, :not_initialized}` if still awaiting a peer sync.
  """
  @spec get_key() :: {:ok, binary()} | {:error, :not_initialized}
  def get_key do
    GenServer.call(__MODULE__, :get_key)
  end

  @doc """
  Accept a master key received from a peer node.

  Persists it to disk and transitions the store to `:ready`.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec set_key(binary()) :: :ok | {:error, atom()}
  def set_key(key) when byte_size(key) == @key_size do
    GenServer.call(__MODULE__, {:set_key, key})
  end

  def set_key(_), do: {:error, :invalid_key_size}

  @doc "Returns `true` if this node has a loaded master key."
  @spec has_key?() :: boolean()
  def has_key? do
    GenServer.call(__MODULE__, :has_key?)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(opts) do
    key_path = Keyword.get(opts, :key_path, default_key_path())

    case read_key_from_disk(key_path) do
      {:ok, key} ->
        Logger.info("KeyStore: loaded master key from #{key_path}")
        {:ok, %{key: key, status: :ready, key_path: key_path}}

      {:error, :enoent} ->
        # No key file – generate a new one (first node scenario).
        # When mesh peer discovery is wired up, this branch can
        # instead enter :awaiting_key and let the mesh provide it.
        key = :crypto.strong_rand_bytes(@key_size)
        :ok = write_key_to_disk(key, key_path)
        Logger.info("KeyStore: generated new master key at #{key_path}")
        {:ok, %{key: key, status: :ready, key_path: key_path}}

      {:error, reason} ->
        Logger.error("KeyStore: failed to read key file – #{inspect(reason)}")
        {:stop, {:key_file_error, reason}}
    end
  end

  @impl true
  def handle_call(:get_key, _from, %{status: :ready, key: key} = state) do
    {:reply, {:ok, key}, state}
  end

  def handle_call(:get_key, _from, %{status: :awaiting_key} = state) do
    {:reply, {:error, :not_initialized}, state}
  end

  def handle_call({:set_key, key}, _from, %{key_path: key_path} = state) do
    case write_key_to_disk(key, key_path) do
      :ok ->
        Logger.info("KeyStore: master key received from peer and persisted")
        {:reply, :ok, %{state | key: key, status: :ready}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:has_key?, _from, %{status: status} = state) do
    {:reply, status == :ready, state}
  end

  # ── Disk persistence (encrypted at rest) ────────────────────────────────

  defp read_key_from_disk(path) do
    case File.read(path) do
      {:ok, <<salt::binary-size(@salt_size), iv::binary-16, tag::binary-16, ciphertext::binary>>} ->
        device_key = derive_device_key(salt)

        case :crypto.crypto_one_time_aead(@aes_mode, device_key, iv, ciphertext, "", tag, false) do
          :error -> {:error, :decrypt_failed}
          plaintext -> {:ok, plaintext}
        end

      {:ok, _} ->
        {:error, :corrupt_key_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_key_to_disk(key, path) do
    File.mkdir_p!(Path.dirname(path))

    salt = :crypto.strong_rand_bytes(@salt_size)
    device_key = derive_device_key(salt)
    iv = :crypto.strong_rand_bytes(16)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(@aes_mode, device_key, iv, key, "", true)

    File.write(path, salt <> iv <> tag <> ciphertext)
  end

  # ── Device key derivation ───────────────────────────────────────────────

  defp derive_device_key(salt) do
    machine_id = read_machine_id()

    :crypto.pbkdf2_hmac(:sha256, machine_id, salt, @pbkdf2_iterations, @key_size)
  end

  defp read_machine_id do
    case File.read("/etc/machine-id") do
      {:ok, id} ->
        String.trim(id)

      {:error, _} ->
        # Fallback: hostname + a stable identifier
        {:ok, hostname} = :inet.gethostname()
        to_string(hostname)
    end
  end

  defp default_key_path do
    Application.get_env(:core, :key_path, Path.expand("~/.dust/master.key"))
  end
end
