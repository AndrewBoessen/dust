defmodule Dust.Mesh.SharedMap do
  @moduledoc """
  Behaviour and boilerplate for distributed shared maps backed by DeltaCrdt.
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer

      require Logger

      @crdt_name :"#{__MODULE__}.CRDT"

      # ── Child spec ──────────────────────────────────────────────────────────

      def child_spec(_opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [[]]},
          type: :supervisor
        }
      end

      def start_link(_opts) do
        children = [
          {DeltaCrdt, [crdt: DeltaCrdt.AWLWWMap, name: @crdt_name, sync_interval: 200]},
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

      defp crdt_put(key, value) do
        DeltaCrdt.put(@crdt_name, key, value)
        :ok
      rescue
        e ->
          Logger.error("#{__MODULE__}: crdt_put failed: #{Exception.message(e)}")
          {:error, :crdt_unavailable}
      end

      defp crdt_delete(key) do
        DeltaCrdt.delete(@crdt_name, key)
        :ok
      rescue
        e ->
          Logger.error("#{__MODULE__}: crdt_delete failed: #{Exception.message(e)}")
          {:error, :crdt_unavailable}
      end

      defp crdt_get(key) do
        DeltaCrdt.get(@crdt_name, key)
      rescue
        e ->
          Logger.error("#{__MODULE__}: crdt_get failed: #{Exception.message(e)}")
          nil
      end

      defp crdt_to_map do
        DeltaCrdt.to_map(@crdt_name)
      rescue
        e ->
          Logger.error("#{__MODULE__}: crdt_to_map failed: #{Exception.message(e)}")
          %{}
      end

      # Allow using modules to override callbacks if needed
      defoverridable init: 1, handle_info: 2, child_spec: 1
    end
  end
end
