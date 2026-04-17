defmodule Dust.Api.EventStream do
  @moduledoc """
  WebSocket handler that streams real-time daemon events to connected clients.

  Subscribes to the `Dust.Daemon.Registry` PubSub topics and relays events
  as JSON messages over the WebSocket connection.

  ## Events

    * `{"type": "download_progress", "file_id": "...", "chunk": 3, "total": 10}`
    * `{"type": "upload_progress", "file_id": "...", "chunk": 3, "total": 10}`
    * `{"type": "system_ready", "node": "dust@100.64.0.1"}`

  ## Connection

  Connect to `ws://localhost:4884/api/v1/ws/events` with the bearer token
  as a query parameter: `?token=<hex-token>`.
  """

  @behaviour WebSock

  require Logger

  # ── WebSock callbacks ──────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Subscribe to daemon PubSub topics
    Registry.register(Dust.Daemon.Registry, :download_progress, [])
    Registry.register(Dust.Daemon.Registry, :upload_progress, [])
    Registry.register(Dust.Daemon.Registry, :system_ready, [])

    Logger.debug("EventStream: WebSocket client connected")
    {:ok, %{}}
  end

  @impl true
  def handle_in({_message, _opts}, state) do
    # We don't process incoming messages from clients
    {:ok, state}
  end

  @impl true
  def handle_info({:download_progress, file_uuid, chunk_index, total_chunks}, state) do
    event =
      Jason.encode!(%{
        type: "download_progress",
        file_id: file_uuid,
        chunk: chunk_index,
        total: total_chunks
      })

    {:push, {:text, event}, state}
  end

  def handle_info({:upload_progress, file_uuid, chunk_index, total_chunks}, state) do
    event =
      Jason.encode!(%{
        type: "upload_progress",
        file_id: file_uuid,
        chunk: chunk_index,
        total: total_chunks
      })

    {:push, {:text, event}, state}
  end

  def handle_info({:system_ready, node_name}, state) do
    event =
      Jason.encode!(%{
        type: "system_ready",
        node: to_string(node_name)
      })

    {:push, {:text, event}, state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.debug("EventStream: WebSocket client disconnected")
    :ok
  end
end
