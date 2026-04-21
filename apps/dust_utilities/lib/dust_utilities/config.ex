defmodule Dust.Utilities.Config do
  @moduledoc """
  Centralized, YAML-backed configuration for the Dust umbrella.

  All user-tunable settings are accessed through this module.
  Callers never need to know which OTP application key to query.

  ## Boot-time settings (immutable after start)

    * `:persist_dir`  — root directory for all persistent data (default `~/.dust`)
    * `:erasure_k`    — Reed-Solomon data shard count (default 4)
    * `:erasure_m`    — Reed-Solomon parity shard count (default 2)

  ## Runtime-mutable settings

    * `:replication_factor`         — min copies on other nodes before GC eviction (default 2)
    * `:disk_quota_bytes`            — max bytes this node may store (default 50 GB)
    * `:stale_node_timeout_ms`       — ms an offline node must be gone before its shard
                                        entries are pruned from the manifest (default 24 h)
    * `:max_reconstruct_per_sweep`   — max chunks the repair scheduler will reconstruct
                                        via erasure coding per sweep (default 5)

  Runtime changes are automatically persisted back to `<persist_dir>/config.yaml`.

  ## Configuration sources (highest priority first)

    1. `config/*.exs`              — boot-time Elixir config overrides
    2. `<persist_dir>/config.yaml` — user-facing YAML config file
    3. Hardcoded defaults in this module
  """

  require Logger

  @defaults %{
    persist_dir: :derived,
    erasure_k: 4,
    erasure_m: 2,
    replication_factor: 2,
    disk_quota_bytes: 50_000_000_000,
    stale_node_timeout_ms: 86_400_000,
    max_reconstruct_per_sweep: 5,
    api_port: 4884,
    api_bind: "127.0.0.1",
    root_dir_id: ""
  }

  @boot_only_keys [:persist_dir, :erasure_k, :erasure_m]
  @runtime_keys [
    :replication_factor,
    :disk_quota_bytes,
    :stale_node_timeout_ms,
    :max_reconstruct_per_sweep,
    :api_port,
    :api_bind,
    :root_dir_id
  ]
  @all_keys @boot_only_keys ++ @runtime_keys

  @config_filename "config.yaml"

  @yaml_header """
  # Dust node configuration
  # ────────────────────────
  #
  # persist_dir        — Root directory for all persistent data.
  #                      Changing after initial setup requires migrating data manually.
  #
  # erasure_k          — Reed-Solomon data shard count (fixed at boot).
  # erasure_m          — Reed-Solomon parity shard count (fixed at boot).
  #                      Any K of K+M shards can reconstruct the original data.
  #
  # replication_factor — Minimum copies on OTHER online nodes before GC evicts
  #                      the local copy. Can be changed at runtime.
  #
  # disk_quota_bytes   — Maximum bytes this node will store locally.
  #                      Can be changed at runtime. Default: 50 GB.
  #
  # stale_node_timeout_ms — Milliseconds an offline node must be gone before its
  #                         shard entries are pruned from the manifest. Default: 24 h.
  #
  # max_reconstruct_per_sweep — Maximum chunks the repair scheduler will reconstruct
  #                             via erasure coding per sweep cycle. Default: 5.
  #
  # api_port              — TCP port for the local HTTP API. Default: 4884.
  #
  # api_bind              — IP address the HTTP API binds to.
  #                         Use "127.0.0.1" (default) to restrict to localhost.
  #
  # root_dir_id           — UUID of the root filesystem directory.
  #                         Set automatically during setup or can be empty.
  #
  """

  # ── Read API ──────────────────────────────────────────────────────────

  @doc "Root directory for all persistent data."
  @spec persist_dir() :: Path.t()
  def persist_dir, do: get(:persist_dir)

  @doc "Reed-Solomon data shard count."
  @spec erasure_k() :: pos_integer()
  def erasure_k, do: get(:erasure_k)

  @doc "Reed-Solomon parity shard count."
  @spec erasure_m() :: pos_integer()
  def erasure_m, do: get(:erasure_m)

  @doc "Minimum other-node copies before GC eviction."
  @spec replication_factor() :: pos_integer()
  def replication_factor, do: get(:replication_factor)

  @doc "Maximum bytes this node may store."
  @spec disk_quota_bytes() :: pos_integer()
  def disk_quota_bytes, do: get(:disk_quota_bytes)

  @doc "Milliseconds before an offline node's shard entries are pruned."
  @spec stale_node_timeout_ms() :: pos_integer()
  def stale_node_timeout_ms, do: get(:stale_node_timeout_ms)

  @doc "Max chunks to reconstruct per repair sweep."
  @spec max_reconstruct_per_sweep() :: pos_integer()
  def max_reconstruct_per_sweep, do: get(:max_reconstruct_per_sweep)

  @doc "TCP port for the local HTTP API."
  @spec api_port() :: pos_integer()
  def api_port, do: get(:api_port)

  @doc "IP address the HTTP API binds to."
  @spec api_bind() :: String.t()
  def api_bind, do: get(:api_bind)

  @doc "UUID of the root directory."
  @spec root_dir_id() :: String.t()
  def root_dir_id, do: get(:root_dir_id)

  @doc "Total shard count (K + M)."
  @spec total_shards() :: pos_integer()
  def total_shards, do: erasure_k() + erasure_m()

  @doc "Returns the full resolved config as a map."
  @spec all() :: map()
  def all, do: resolved_config()

  @doc "Path to the YAML config file."
  @spec config_path() :: Path.t()
  def config_path, do: Path.join(persist_dir(), @config_filename)

  # ── Write API (runtime-mutable keys only) ─────────────────────────────

  @doc """
  Updates a runtime-mutable configuration key and persists the change
  to `config.yaml`.

  Returns `:ok` on success or `{:error, reason}` if the key is
  boot-only or the value fails validation.
  """
  @spec put(atom(), term()) :: :ok | {:error, term()}
  def put(key, value) when key in @runtime_keys do
    with :ok <- validate_key(key, value) do
      config = resolved_config()
      new_config = Map.put(config, key, value)
      Application.put_env(:dust_utilities, :config, new_config)
      save_yaml!(new_config)
      :ok
    end
  end

  def put(key, _value) when key in @boot_only_keys,
    do: {:error, {:immutable_after_boot, key}}

  def put(key, _value),
    do: {:error, {:unknown_key, key}}

  # ── Boot ──────────────────────────────────────────────────────────────

  @doc """
  Called once at application start. Loads the YAML config file, merges
  with defaults and compile-time overrides, validates the result, and
  seeds the application env for fast reads.

  Creates a default `config.yaml` if none exists.
  """
  @spec load!() :: :ok
  def load! do
    # Step 1: resolve persist_dir (must be known before reading YAML)
    base_dir = resolve_persist_dir()
    File.mkdir_p!(base_dir)

    # Step 2: read YAML (may not exist yet)
    yaml_values = load_yaml(base_dir)

    # Step 3: merge  defaults < yaml < compile-time overrides
    #   compile overrides may contain only a subset of keys (e.g. just persist_dir)
    compile_overrides = Application.get_env(:dust_utilities, :config, %{})

    config =
      @defaults
      |> Map.put(:persist_dir, base_dir)
      |> Map.merge(yaml_values)
      |> Map.merge(compile_overrides)
      # persist_dir is always from step 1 (compile overrides already factored in)
      |> Map.put(:persist_dir, base_dir)

    # Step 4: validate
    validate!(config)

    # Step 5: store in app env for fast reads
    Application.put_env(:dust_utilities, :config, config)

    # Step 6: write default YAML if file does not exist
    yaml_path = Path.join(base_dir, @config_filename)

    unless File.exists?(yaml_path) do
      save_yaml!(config)
      Logger.info("Created default config at #{yaml_path}")
    end

    Logger.info("Config loaded: #{inspect(config)}")
    :ok
  end

  # ── Test helper ───────────────────────────────────────────────────────

  @doc """
  Temporarily overrides config keys for the duration of `block`, then
  restores the previous values.

  ## Example

      import Dust.Utilities.Config

      with_config(persist_dir: "/tmp/test", replication_factor: 1) do
        assert Config.persist_dir() == "/tmp/test"
      end
  """
  defmacro with_config(overrides, do: block) do
    quote do
      old_config = Application.get_env(:dust_utilities, :config)

      try do
        merged =
          Map.merge(
            Dust.Utilities.Config.all(),
            Map.new(unquote(overrides))
          )

        Application.put_env(:dust_utilities, :config, merged)
        unquote(block)
      after
        if old_config do
          Application.put_env(:dust_utilities, :config, old_config)
        else
          Application.delete_env(:dust_utilities, :config)
        end
      end
    end
  end

  # ── Internal ──────────────────────────────────────────────────────────

  @spec get(atom()) :: term()
  defp get(key), do: Map.fetch!(resolved_config(), key)

  @spec resolved_config() :: map()
  defp resolved_config do
    config = Application.get_env(:dust_utilities, :config, %{})

    @defaults
    |> Map.merge(config)
    |> Map.put(:persist_dir, Map.get(config, :persist_dir) || resolve_persist_dir())
  end

  @spec resolve_persist_dir() :: Path.t()
  defp resolve_persist_dir do
    case Application.get_env(:dust_utilities, :config, %{}) do
      %{persist_dir: dir} when is_binary(dir) and dir != "" -> dir
      _ -> default_persist_dir()
    end
  end

  @spec default_persist_dir() :: Path.t()
  defp default_persist_dir, do: Path.join(System.user_home!(), ".dust")

  # ── YAML I/O ──────────────────────────────────────────────────────────

  @spec load_yaml(Path.t()) :: map()
  defp load_yaml(base_dir) do
    path = Path.join(base_dir, @config_filename)

    case YamlElixir.read_from_file(path) do
      {:ok, map} when is_map(map) -> atomize_keys(map)
      _ -> %{}
    end
  end

  @spec save_yaml!(map()) :: :ok
  defp save_yaml!(config) do
    path = Path.join(Map.fetch!(config, :persist_dir), @config_filename)
    content = encode_yaml(config)
    File.write!(path, content)
  end

  @spec encode_yaml(map()) :: String.t()
  defp encode_yaml(config) do
    lines =
      @all_keys
      |> Enum.map(fn key ->
        value = Map.fetch!(config, key)
        "#{key}: #{yaml_value(value)}"
      end)
      |> Enum.join("\n")

    @yaml_header <> lines <> "\n"
  end

  defp yaml_value(v) when is_binary(v), do: v
  defp yaml_value(v) when is_integer(v), do: Integer.to_string(v)
  defp yaml_value(v), do: inspect(v)

  @spec atomize_keys(map()) :: map()
  defp atomize_keys(map) do
    for {k, v} <- map,
        key = safe_to_atom(k),
        key in @all_keys,
        not is_nil(v),
        into: %{} do
      {key, v}
    end
  end

  @spec safe_to_atom(String.t() | atom()) :: atom() | nil
  defp safe_to_atom(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> nil
    end
  end

  defp safe_to_atom(a) when is_atom(a), do: a

  # ── Validation ────────────────────────────────────────────────────────

  @spec validate!(map()) :: :ok
  defp validate!(config) do
    Enum.each(@all_keys, fn key ->
      case validate_key(key, Map.fetch!(config, key)) do
        :ok ->
          :ok

        {:error, reason} ->
          raise ArgumentError,
                "Dust.Utilities.Config: invalid #{key} = #{inspect(Map.get(config, key))}: #{inspect(reason)}"
      end
    end)

    :ok
  end

  @spec validate_key(atom(), term()) :: :ok | {:error, term()}
  defp validate_key(:erasure_k, v) when is_integer(v) and v >= 1, do: :ok
  defp validate_key(:erasure_m, v) when is_integer(v) and v >= 1, do: :ok
  defp validate_key(:replication_factor, v) when is_integer(v) and v >= 1, do: :ok
  defp validate_key(:disk_quota_bytes, v) when is_integer(v) and v > 0, do: :ok
  defp validate_key(:stale_node_timeout_ms, v) when is_integer(v) and v > 0, do: :ok
  defp validate_key(:max_reconstruct_per_sweep, v) when is_integer(v) and v >= 0, do: :ok
  defp validate_key(:persist_dir, v) when is_binary(v) and v != "", do: :ok
  defp validate_key(:api_port, v) when is_integer(v) and v > 0 and v <= 65535, do: :ok
  defp validate_key(:api_bind, v) when is_binary(v) and v != "", do: :ok
  defp validate_key(:root_dir_id, v) when is_binary(v), do: :ok
  defp validate_key(key, value), do: {:error, {key, :invalid, value}}
end
