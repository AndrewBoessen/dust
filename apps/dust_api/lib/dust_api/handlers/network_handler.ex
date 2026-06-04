defmodule Dust.Api.Handlers.NetworkHandler do
  @moduledoc """
  Network startup endpoints.

  `POST /api/v1/network/start` lazily spawns the Go `tsnet_sidecar`.

  The bridge boots in **deferred mode** when no keystore exists on disk
  so that Tailscale doesn't register the node under the placeholder
  `node_name` (`"dust"`). `dustctl init` and the Web UI's `SetupLive`
  call this endpoint AFTER the user has picked their device name, so
  the sidecar's Tailscale identity is correct on its first connection.

  No-op (returns 200) when the sidecar is already running.
  """

  import Plug.Conn

  @doc "Start the Tailscale sidecar (or no-op if already running)."
  @spec start(Plug.Conn.t()) :: Plug.Conn.t()
  def start(conn) do
    case Dust.Bridge.start_sidecar() do
      :ok ->
        json_response(conn, 200, %{status: "started"})

      {:error, reason} ->
        json_response(conn, 500, %{error: inspect(reason)})
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
