defmodule Dust.Daemon.DiskManager do
  @moduledoc """
  Background daemon that manages the local storage capactities.
  """
  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sets the maximum storage quota (in bytes) to allocate on this node.
  Validates that the host filesystem physically has enough capacity.
  """
  @spec set_quota(non_neg_integer()) :: :ok | {:error, term()}
  def set_quota(bytes) when is_integer(bytes) and bytes > 0 do
    GenServer.call(__MODULE__, {:set_quota, bytes})
  end

  @doc """
  Returns the currently configured maximum storage quota in bytes.
  """
  @spec get_quota() :: non_neg_integer()
  def get_quota() do
    GenServer.call(__MODULE__, :get_quota)
  end

  @doc """
  Checks if there is enough space within the configured quota and the underlying
  host filesystem to allocate the given list of shards (binaries).
  """
  @spec can_allocate?([binary()]) :: boolean()
  def can_allocate?(shards) when is_list(shards) do
    total_bytes =
      shards
      |> Enum.map(&byte_size/1)
      |> Enum.sum()

    can_allocate_bytes?(total_bytes)
  end

  @doc """
  Checks if there is enough space within the configured quota and the underlying
  host filesystem to allocate the requested amount of bytes.
  """
  @spec can_allocate_bytes?(non_neg_integer()) :: boolean()
  def can_allocate_bytes?(bytes) when is_integer(bytes) and bytes >= 0 do
    quota = get_quota()
    current_size = dir_size(Dust.Utilities.File.storage_db_dir())

    if current_size + bytes <= quota do
      stats = DiskSpace.stat!(Dust.Utilities.File.persist_dir())
      stats.available >= bytes
    else
      false
    end
  end

  @spec dir_size(String.t()) :: non_neg_integer()
  defp dir_size(path) do
    case File.ls(path) do
      {:ok, files} ->
        Enum.map(files, fn file ->
          full_path = Path.join(path, file)

          case File.stat(full_path) do
            {:ok, %{type: :directory}} -> dir_size(full_path)
            {:ok, %{size: size}} -> size
            _ -> 0
          end
        end)
        |> Enum.sum()

      _ ->
        0
    end
  end

  @impl true
  def init(_opts) do
    Logger.info("Starting Disk Quota Manager daemon.")

    # 50 GB
    default_quota = 50_000_000_000
    quota_bytes = load_quota(default_quota)
    state = %{quota_bytes: quota_bytes}

    # Verify if we still have the capacity we booted with
    # (Just a warning, we shouldn't crash here so the node can boot and be fixed)
    check_os_capacity(quota_bytes)

    {:ok, state}
  end

  @impl true
  def handle_call({:set_quota, bytes}, _from, state) do
    case check_os_capacity(bytes) do
      :ok ->
        save_quota(bytes)
        {:reply, :ok, %{state | quota_bytes: bytes}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_quota, _from, %{quota_bytes: bytes} = state) do
    {:reply, bytes, state}
  end

  # --- Privates ---

  @spec check_os_capacity(non_neg_integer()) :: :ok | {:error, :insufficient_disk_space}
  defp check_os_capacity(requested_bytes) do
    path = Dust.Utilities.File.persist_dir()

    # Ensure directory exists before querying disk space
    File.mkdir_p!(path)

    stats = DiskSpace.stat!(path)

    if stats.available >= requested_bytes do
      :ok
    else
      Logger.warning(
        "Insufficient actual disk space on #{path}. Requested: #{requested_bytes}, Available: #{stats.available}"
      )

      {:error, :insufficient_disk_space}
    end
  end

  @spec config_file_path() :: String.t()
  defp config_file_path do
    Dust.Utilities.File.disk_quota_file()
  end

  @spec load_quota(non_neg_integer()) :: non_neg_integer()
  defp load_quota(default_quota) do
    case File.read(config_file_path()) do
      {:ok, body} ->
        # Simple decode without pulling in a whole JSON library 
        # (assuming Jason is available based on deps.get)
        case Code.ensure_loaded(Jason) do
          {:module, _} ->
            case Jason.decode(body) do
              {:ok, %{"quota_bytes" => val}} -> val
              _ -> default_quota
            end

          {:error, _} ->
            default_quota
        end

      {:error, _} ->
        default_quota
    end
  end

  @spec save_quota(non_neg_integer()) :: :ok | {:error, File.posix()}
  defp save_quota(bytes) do
    payload = %{"quota_bytes" => bytes}

    if Code.ensure_loaded?(Jason) do
      File.write(config_file_path(), Jason.encode!(payload))
    end
  end
end
