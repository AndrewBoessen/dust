defmodule Dust.Mesh.SharedMap do
  @moduledoc """
  Reusable macro that provisions a CRDT-backed distributed map.

  `use Dust.Mesh.SharedMap` injects a supervised `DeltaCrdt.AWLWWMap`
  (add-wins last-writer-wins map) and a companion GenServer into the
  calling module. The GenServer subscribes to `Dust.Mesh.NodeRegistry`
  and automatically updates the CRDT's neighbour set whenever cluster
  membership changes, ensuring data syncs to all connected nodes.

  ## Usage

      defmodule MyApp.Tags do
        use Dust.Mesh.SharedMap

        def put(id, tag),  do: crdt_put(id, tag)
        def get(id),       do: crdt_get(id)
        def delete(id),    do: crdt_delete(id)
        def all(),         do: crdt_to_map()
      end

  ## Injected helpers (private to the using module)

    * `crdt_put/2`     — insert or update a key/value pair.
    * `crdt_get/1`     — read a single key (returns `nil` if missing or CRDT unavailable).
    * `crdt_delete/1`  — remove a key.
    * `crdt_to_map/0`  — snapshot the entire map as a plain Elixir map.

  All helpers rescue `exit` signals from the CRDT process and return safe
  fallbacks (`:ok | {:error, :crdt_unavailable}` for writes, `nil` / `%{}`
  for reads) so that transient CRDT downtime does not crash the caller.

  ## Persistence

  CRDT state is persisted through `Dust.Mesh.SharedMap.Storage`, which
  writes snapshots to the shared `Dust.Mesh.Database` (CubDB) instance.
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer

      require Logger

      @crdt_name :"#{__MODULE__}.CRDT"

      # ── Child spec ──────────────────────────────────────────────────────────

      @doc false
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(_opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [[]]},
          type: :supervisor
        }
      end

      @doc false
      @spec start_link(keyword()) :: Supervisor.on_start()
      def start_link(_opts) do
        children = [
          {DeltaCrdt,
           [
             crdt: DeltaCrdt.AWLWWMap,
             name: @crdt_name,
             sync_interval: 200,
             storage_module: Dust.Mesh.SharedMap.Storage
           ]},
          %{
            id: :"#{__MODULE__}.Server",
            start: {GenServer, :start_link, [__MODULE__, [], [name: __MODULE__]]}
          }
        ]

        Supervisor.start_link(children,
          strategy: :rest_for_one,
          name: :"#{__MODULE__}.Supervisor"
        )
      end

      # ── GenServer callbacks ──────────────────────────────────────────────────

      @impl true
      def init(_opts) do
        Dust.Mesh.NodeRegistry.subscribe()
        Logger.info("#{__MODULE__}: started on #{Node.self()}")
        {:ok, %{}}
      end

      @impl true
      def handle_info({:node_registry_changed, online_nodes}, state) do
        neighbours = Enum.map(online_nodes, fn node -> {@crdt_name, node} end)
        DeltaCrdt.set_neighbours(@crdt_name, neighbours)
        {:noreply, state}
      end

      def handle_info(unexpected, state) do
        Logger.warning("#{__MODULE__}: received unexpected message: #{inspect(unexpected)}")
        {:noreply, state}
      end

      # ── Protected CRDT helpers — called by the using module's typed API ──────

      @spec crdt_put(term(), term()) :: :ok | {:error, :crdt_unavailable}
      defp crdt_put(key, value) do
        DeltaCrdt.put(@crdt_name, key, value)
        :ok
      rescue
        e ->
          Logger.error("#{__MODULE__}: crdt_put failed: #{Exception.message(e)}")
          {:error, :crdt_unavailable}
      catch
        :exit, reason ->
          Logger.error("#{__MODULE__}: crdt_put failed (exit): #{inspect(reason)}")
          {:error, :crdt_unavailable}
      end

      @spec crdt_delete(term()) :: :ok | {:error, :crdt_unavailable}
      defp crdt_delete(key) do
        DeltaCrdt.delete(@crdt_name, key)
        :ok
      rescue
        e ->
          Logger.error("#{__MODULE__}: crdt_delete failed: #{Exception.message(e)}")
          {:error, :crdt_unavailable}
      catch
        :exit, reason ->
          Logger.error("#{__MODULE__}: crdt_delete failed (exit): #{inspect(reason)}")
          {:error, :crdt_unavailable}
      end

      @spec crdt_get(term()) :: term() | nil
      defp crdt_get(key) do
        DeltaCrdt.get(@crdt_name, key)
      rescue
        e ->
          Logger.error("#{__MODULE__}: crdt_get failed: #{Exception.message(e)}")
          nil
      catch
        :exit, reason ->
          Logger.error("#{__MODULE__}: crdt_get failed (exit): #{inspect(reason)}")
          nil
      end

      @spec crdt_to_map() :: map()
      defp crdt_to_map do
        DeltaCrdt.to_map(@crdt_name)
      rescue
        e ->
          Logger.error("#{__MODULE__}: crdt_to_map failed: #{Exception.message(e)}")
          %{}
      catch
        :exit, reason ->
          Logger.error("#{__MODULE__}: crdt_to_map failed (exit): #{inspect(reason)}")
          %{}
      end

      # Allow using modules to override callbacks if needed
      defoverridable init: 1, handle_info: 2, child_spec: 1
    end
  end

  defmodule Storage do
    @moduledoc """
    DeltaCrdt storage backend that persists CRDT snapshots to CubDB.

    Implements the `DeltaCrdt.Storage` behaviour. Each CRDT instance is
    stored under its process name as the CubDB key, inside the shared
    `Dust.Mesh.Database` instance.
    """
    @behaviour DeltaCrdt.Storage

    @impl true
    @spec write(atom(), term()) :: :ok
    def write(crdt_name, storage_format) do
      CubDB.put(Dust.Mesh.Database, crdt_name, storage_format)
    end

    @impl true
    @spec read(atom()) :: term() | nil
    def read(crdt_name) do
      CubDB.get(Dust.Mesh.Database, crdt_name)
    end
  end
end
