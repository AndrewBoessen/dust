defmodule Dust.Daemon.Join do
  @moduledoc """
  Orchestrates joining an existing Dust network.

  `Dust.Bridge.join/2` only *retrieves* the network's OTP cookie and master
  key from a peer over Tailscale. Joining means **adopting** both:

    * the **OTP cookie**, or Erlang distribution rejects this node's
      handshake with `Invalid challenge reply` and it never becomes a
      cluster member;
    * the **master key**, which wraps every file key. Without it the node
      cannot unwrap files created elsewhere in the cluster (every download
      fails with `:integrity_check_failed`), while the files it writes are
      unreadable to every other node.

  ## Replacing the master key

  Adopting the network's master key replaces the one this node minted for
  itself, so anything already encrypted under the old key becomes
  unreadable. The node only adopts silently when it can positively confirm
  it holds no data. If it holds data — or if local storage cannot be
  inspected — the caller gets `{:error, :local_data_exists, counts}` and
  nothing is changed; passing `force: true` then proceeds.

  Nothing is adopted unless the whole join can go through: a rejected join
  leaves the node exactly as it was, rather than half-joined with a working
  cookie and the wrong key.
  """

  require Logger

  alias Dust.Core.KeyStore

  @key_size 32

  @typedoc "Counts of locally held data, or `:unknown` when it can't be read."
  @type local_data :: %{shards: non_neg_integer() | :unknown, files: non_neg_integer() | :unknown}

  @typedoc """
  What happened to the master key:

    * `:adopted` — this node's key was replaced by the network's
    * `:already_current` — the node already held the network's key
    * `:deferred` — the key store is locked and has no key on disk yet, so
      the fetched key is cached and adopted at the first unlock
  """
  @type outcome :: :adopted | :already_current | :deferred

  @doc """
  Joins the network reachable at `peer_address` using a one-time invite `token`.

  Options:

    * `:force` — adopt the network's master key even though this node
      already holds data encrypted under its own key. Defaults to `false`.
  """
  @spec join(String.t(), String.t(), keyword()) ::
          {:ok, outcome()}
          | {:error, :local_data_exists, local_data()}
          | {:error, term()}
  def join(peer_address, token, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    with {:ok, master_key_b64, otp_cookie} <- bridge_module().join(peer_address, token),
         {:ok, master_key} <- decode_master_key(master_key_b64),
         :ok <- check_key_adoption(master_key, force?),
         :ok <- Dust.Bridge.Secrets.adopt_joined_secrets(master_key_b64, otp_cookie) do
      adopt_master_key(master_key)
    end
  end

  @doc """
  Counts the data this node holds locally.

  Returns `:unknown` when storage or the mesh cannot be inspected — callers
  must treat that as "may hold data", never as empty.
  """
  @spec local_data() :: {:ok, local_data()} | :unknown
  def local_data do
    {:ok,
     %{
       shards: length(Dust.Storage.list_local_shard_keys()),
       files: map_size(Dust.Mesh.FileSystem.FileMap.all())
     }}
  rescue
    error ->
      Logger.warning("Join: could not inspect local data: #{inspect(error)}")
      :unknown
  catch
    :exit, reason ->
      Logger.warning("Join: could not inspect local data: #{inspect(reason)}")
      :unknown
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec decode_master_key(String.t()) :: {:ok, binary()} | {:error, atom()}
  defp decode_master_key(master_key_b64) do
    case Base.decode64(master_key_b64) do
      {:ok, key} when byte_size(key) == @key_size -> {:ok, key}
      {:ok, _key} -> {:error, :invalid_key_size}
      :error -> {:error, :invalid_master_key}
    end
  end

  # Decides whether the master key may be replaced, without changing anything.
  @spec check_key_adoption(binary(), boolean()) ::
          :ok | {:error, :local_data_exists, local_data()} | {:error, :key_store_locked}
  defp check_key_adoption(master_key, force?) do
    case current_key() do
      {:ok, ^master_key} ->
        :ok

      {:ok, _different_key} ->
        if force?, do: :ok, else: require_empty_node()

      {:error, :locked} ->
        # A locked store can neither be compared against nor rewritten. With
        # no key on disk the first unlock adopts the fetched one, so the
        # join is still safe to complete.
        if File.exists?(Dust.Utilities.File.master_key_file()) do
          {:error, :key_store_locked}
        else
          :ok
        end
    end
  end

  @spec require_empty_node() :: :ok | {:error, :local_data_exists, local_data()}
  defp require_empty_node do
    case local_data() do
      {:ok, %{shards: 0, files: 0}} -> :ok
      {:ok, counts} -> {:error, :local_data_exists, counts}
      :unknown -> {:error, :local_data_exists, %{shards: :unknown, files: :unknown}}
    end
  end

  @spec adopt_master_key(binary()) :: {:ok, outcome()} | {:error, term()}
  defp adopt_master_key(master_key) do
    case current_key() do
      {:ok, ^master_key} ->
        {:ok, :already_current}

      {:ok, _different_key} ->
        case KeyStore.set_key(master_key) do
          :ok ->
            Logger.info("Join: adopted the network's master key")
            {:ok, :adopted}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :locked} ->
        Logger.info("Join: key store locked — network master key cached for first unlock")
        {:ok, :deferred}
    end
  end

  @spec current_key() :: {:ok, binary()} | {:error, :locked}
  defp current_key do
    KeyStore.get_key()
  catch
    :exit, _reason -> {:error, :locked}
  end

  @spec bridge_module() :: module()
  defp bridge_module do
    Application.get_env(:dust_bridge, :bridge_module, Dust.Bridge)
  end
end
