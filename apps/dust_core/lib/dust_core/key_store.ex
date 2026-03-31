defmodule Dust.Core.KeyStore do
  @moduledoc """
  Manages the network-wide master key lifecycle using a vault-unlock pattern.

  The GenServer boots into a `:locked` state. No disk I/O or key material is
  touched until the user provides their password via `unlock/1`.

  ## Unlock flow

    * **Key file exists** – derives a device key from `password <> machine-id`
      via PBKDF2, decrypts the master key, and transitions to `:ready`.
    * **Key file missing** – generates a fresh 32-byte master key, encrypts it
      at rest with the derived device key, persists it, and transitions to `:ready`.
    * **Wrong password** – decryption fails, the store stays `:locked`.

  The `lock/0` function wipes the key from state and returns to `:locked`.
  The password is never stored — it is only held in memory during the
  PBKDF2 derivation call inside `unlock/1`.
  """

  use GenServer

  require Logger

  @key_size 32
  @salt_size 16
  @aes_mode :aes_256_gcm

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Start the KeyStore GenServer under a supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Unlock the key store with the user's password.

  Derives a device-bound key from `password <> machine-id` via Argon2,
  then either decrypts an existing master key from disk or generates a
  new one on first boot. The password is discarded after derivation.

  Returns `:ok` on success, `{:error, :decrypt_failed}` for a wrong
  password, or `{:error, :already_unlocked}` if already in `:ready` state.
  """
  @spec unlock(String.t()) :: :ok | {:error, :decrypt_failed | :already_unlocked}
  def unlock(password) when is_binary(password) do
    GenServer.call(__MODULE__, {:unlock, password})
  end

  @doc """
  Lock the key store, wiping the master key from memory.

  Returns `:ok`. The store transitions back to `:locked`.
  """
  @spec lock() :: :ok
  def lock do
    GenServer.call(__MODULE__, :lock)
  end

  @doc """
  Retrieve the master key.

  Returns `{:ok, <<key::256>>}` when unlocked,
  or `{:error, :locked}` if the store has not been unlocked yet.
  """
  @spec get_key() :: {:ok, binary()} | {:error, :locked}
  def get_key do
    GenServer.call(__MODULE__, :get_key)
  end

  @doc """
  Accept a master key received from a peer node.

  Persists it to disk (encrypted with the current device key) and
  keeps the store in `:ready` state.
  Returns `:ok`, `{:error, :locked}`, or `{:error, reason}`.
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
    key_path = Keyword.get(opts, :key_path, Dust.Utilities.File.master_key_file())

    {:ok,
     %{
       key: nil,
       password: nil,
       status: :locked,
       key_path: key_path
     }}
  end

  @impl true
  def handle_call({:unlock, _password}, _from, %{status: :ready} = state) do
    {:reply, {:error, :already_unlocked}, state}
  end

  def handle_call({:unlock, password}, _from, %{status: :locked, key_path: key_path} = state) do
    case File.read(key_path) do
      {:ok, <<salt::binary-size(@salt_size), iv::binary-16, tag::binary-16, ciphertext::binary>>} ->
        device_key = derive_device_key(salt, password)

        case :crypto.crypto_one_time_aead(@aes_mode, device_key, iv, ciphertext, "", tag, false) do
          :error ->
            {:reply, {:error, :decrypt_failed}, state}

          plaintext ->
            Logger.info("KeyStore: unlocked master key from #{key_path}")
            serve_secrets(plaintext)
            {:reply, :ok, %{state | key: plaintext, password: password, status: :ready}}
        end

      {:ok, _} ->
        {:reply, {:error, :decrypt_failed}, state}

      {:error, :enoent} ->
        # First boot — check if the Bridge fetched a key from a peer
        fetched_b64 =
          try do
            Dust.Bridge.Secrets.get_fetched_master_key()
          rescue
            _ -> nil
          end

        key =
          if fetched_b64 do
            Logger.info("KeyStore: Adopting master key fetched via Dust Bridge")

            try do
              Dust.Bridge.Secrets.clear_fetched_master_key()
            rescue
              _ -> :ok
            end

            Base.decode64!(fetched_b64)
          else
            Logger.info("KeyStore: generating new master key")
            :crypto.strong_rand_bytes(@key_size)
          end

        case write_key_to_disk(key, key_path, password) do
          :ok ->
            Logger.info("KeyStore: master key persisted at #{key_path}")
            serve_secrets(key)
            {:reply, :ok, %{state | key: key, password: password, status: :ready}}

          {:error, reason} ->
            Logger.error("KeyStore: generated key but failed to persist – #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        Logger.error("KeyStore: failed to read key file – #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:lock, _from, state) do
    Logger.info("KeyStore: locked")
    {:reply, :ok, %{state | key: nil, password: nil, status: :locked}}
  end

  def handle_call(:get_key, _from, %{status: :ready, key: key} = state) do
    {:reply, {:ok, key}, state}
  end

  def handle_call(:get_key, _from, %{status: :locked} = state) do
    {:reply, {:error, :locked}, state}
  end

  def handle_call({:set_key, _key}, _from, %{status: :locked} = state) do
    {:reply, {:error, :locked}, state}
  end

  def handle_call({:set_key, key}, _from, %{key_path: key_path, password: password} = state) do
    case write_key_to_disk(key, key_path, password) do
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

  # Helper to start serving the key via bridge
  defp serve_secrets(key) do
    try do
      otp_cookie = Node.get_cookie() |> to_string()
      key_b64 = Base.encode64(key)
      bridge_module().serve_secrets(key_b64, otp_cookie)
    rescue
      err ->
        Logger.warning(
          "KeyStore: #{bridge_module()} is not available to serve secrets: #{inspect(err)}"
        )
    end
  end

  defp bridge_module do
    Application.get_env(:dust_bridge, :bridge_module, Dust.Bridge)
  end

  # ── Disk persistence (encrypted at rest) ────────────────────────────────

  defp write_key_to_disk(key, path, password) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      salt = :crypto.strong_rand_bytes(@salt_size)
      device_key = derive_device_key(salt, password)
      iv = :crypto.strong_rand_bytes(16)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(@aes_mode, device_key, iv, key, "", true)

      File.write(path, salt <> iv <> tag <> ciphertext)
    end
  end

  # ── Device key derivation ───────────────────────────────────────────────

  defp derive_device_key(salt, password) do
    machine_id = read_machine_id()
    secret = password <> machine_id

    secret
    |> Argon2.Base.hash_password(salt, format: :raw_hash, hashlen: @key_size, argon2_type: 2)
    |> Base.decode16!(case: :lower)
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
end
