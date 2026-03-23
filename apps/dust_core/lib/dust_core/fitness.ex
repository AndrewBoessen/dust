defmodule Dust.Core.Fitness do
  @moduledoc """
  Calculate node fitness based on network stats.

  The network stats are based on an EMA from historic interactions.
  These fitness scores are relative to each caller node and interactions
  are not shared across the network.
  """

  defmodule Observation do
    @moduledoc """
    The outcome of an interaction with an online peer node.

    `success` indicates whether the interaction resulted in a successfully
    transmitted chunk of data. Latency and bandwidth are nil on failure
    since no meaningful measurement can be taken from an incomplete transfer.
    """
    @type t :: %__MODULE__{
            success: boolean(),
            latency_ms: nil | float(),
            bandwidth: nil | float()
          }
    @enforce_keys [:success, :latency_ms, :bandwidth]
    defstruct [:success, :latency_ms, :bandwidth]
  end

  defmodule NodeEMA do
    @moduledoc """
    Exponential Moving Average model of a node's data transfer performance.

    Tracks three metrics updated only when an online peer is interacted with:

    - `success_rate`: smoothed ratio of successful chunk transfers.
    - `latency_ms`:   smoothed transfer latency in milliseconds. Lower is better.
    - `bandwidth`:    smoothed throughput in Mbps. Higher is better.

    Latency and bandwidth are only updated on successful transfers — a failed
    transfer produces no reliable measurement and is excluded to avoid
    polluting the model with noise.
    """

    @alpha 0.3

    @type t :: %__MODULE__{
            success_rate: float(),
            latency_ms: float(),
            bandwidth: float()
          }

    @enforce_keys [:success_rate, :latency_ms, :bandwidth]
    defstruct success_rate: 0.5, latency_ms: 100.0, bandwidth: 10.0

    @doc "Default model for a peer that has never been interacted with."
    @spec new() :: t()
    def new(), do: %__MODULE__{success_rate: 0.5, latency_ms: 100.0, bandwidth: 10.0}

    @doc """
    Update the model with the outcome of an interaction.

    On failure only `success_rate` is updated. On success all three
    metrics are updated via EMA:

        new_value = alpha * observation + (1 - alpha) * current_value
    """
    @spec update(t(), Dust.Core.Fitness.Observation.t()) :: t()
    def update(model, %Dust.Core.Fitness.Observation{success: false}) do
      %{model | success_rate: ema(model.success_rate, 0.0)}
    end

    def update(model, %Dust.Core.Fitness.Observation{
          success: true,
          latency_ms: latency_ms,
          bandwidth: bandwidth
        }) do
      %{
        model
        | success_rate: ema(model.success_rate, 1.0),
          latency_ms: ema(model.latency_ms, latency_ms),
          bandwidth: ema(model.bandwidth, bandwidth)
      }
    end

    @doc """
    Compute a scalar fitness score.

        success_rate × bandwidth / (1 + latency_ms / 100)
    """
    @spec score(t()) :: float()
    def score(model) do
      model.success_rate *
        model.bandwidth /
        (1.0 + model.latency_ms / 100.0)
    end

    defp ema(current, observation) do
      @alpha * observation + (1.0 - @alpha) * current
    end
  end

  # ── Model Store ───────────────────────────────────────────────────────────

  defmodule ModelStore do
    @moduledoc """
    Persisted ETS-backed store for NodeEMA models.

    Models survive restarts via a CubDB database in `.dust/fitness_models/`.
    The GenServer owns the ETS table for its lifetime — if it crashes and is
    restarted by the supervisor, the table is recreated and models reloaded
    from disk automatically.

    Reads are lock-free via public ETS. Writes are serialised through the
    GenServer via `call` to prevent race conditions between concurrent
    interactions.
    """

    use GenServer

    require Logger

    @table :fitness_models

    # ── Public API ───────────────────────────────────────────────────────────

    @doc "Start the ModelStore GenServer under a supervisor."
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @doc "Get the model for a node, returning a fresh default if unseen."
    @spec get(binary()) :: NodeEMA.t()
    def get(node_id) do
      case :ets.lookup(@table, node_id) do
        [{^node_id, model}] -> model
        [] -> NodeEMA.new()
      end
    end

    @doc """
    Update a node's model with a new observation and persist to disk.

    Serialised through the GenServer to prevent concurrent writes
    from producing inconsistent ETS or disk state.
    """
    @spec update(binary(), Dust.Core.Fitness.Observation.t()) :: NodeEMA.t()
    def update(node_id, observation) do
      GenServer.call(__MODULE__, {:update, node_id, observation})
    end

    # ── GenServer callbacks ───────────────────────────────────────────────────

    @impl true
    def init(opts) do
      db = Keyword.get(opts, :db, Dust.Core.Database)

      :ets.new(@table, [:named_table, :public, read_concurrency: true])
      load(db)

      Logger.info("ModelStore: loaded fitness models from CubDB #{inspect(db)}")
      {:ok, %{db: db}}
    end

    @impl true
    def handle_call({:update, node_id, observation}, _from, state) do
      updated = node_id |> get() |> NodeEMA.update(observation)
      :ets.insert(@table, {node_id, updated})
      CubDB.put(state.db, node_id, updated)
      {:reply, updated, state}
    end

    # ── Private ──────────────────────────────────────────────────────────────

    defp load(db) do
      try do
        # CubDB.select returns a stream of all key/value pairs
        # We iterate and insert them all into the ETS cache on startup
        Enum.each(CubDB.select(db), fn {node_id, model} ->
          :ets.insert(@table, {node_id, model})
        end)
      rescue
        e ->
          Logger.warning(
            "ModelStore: failed to load from CubDB, starting fresh: #{Exception.message(e)}"
          )
      end
    end
  end

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Score a node by its ID.

  Returns the current fitness score for the node. Nodes that have never
  been interacted with return the default model score. Only online peers
  should be scored — availability is tracked separately.
  """
  @spec score(binary()) :: float()
  def score(node_id) do
    node_id
    |> ModelStore.get()
    |> NodeEMA.score()
  end

  @doc """
  Record the outcome of an interaction with a peer and update its model.

  Returns the updated model.
  """
  @spec record(binary(), Observation.t()) :: NodeEMA.t()
  def record(node_id, observation) do
    ModelStore.update(node_id, observation)
  end
end
