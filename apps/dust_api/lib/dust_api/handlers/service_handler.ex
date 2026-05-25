defmodule Dust.Api.Handlers.ServiceHandler do
  @moduledoc """
  Handles service management endpoints — delegates to `Dust.Api.Service`.

    POST   /api/v1/service/install
    DELETE /api/v1/service/uninstall
    GET    /api/v1/service/status
    POST   /api/v1/service/start
    POST   /api/v1/service/stop
  """

  import Plug.Conn

  def install(conn) do
    case Dust.Api.Service.install() do
      :ok ->
        json_response(conn, 200, %{ok: true})

      {:error, reason} ->
        json_response(conn, error_status(reason), %{error: format_reason(reason)})
    end
  end

  def uninstall(conn) do
    case Dust.Api.Service.uninstall() do
      :ok ->
        json_response(conn, 200, %{ok: true})

      {:error, reason} ->
        json_response(conn, error_status(reason), %{error: format_reason(reason)})
    end
  end

  def status(conn) do
    status = Dust.Api.Service.status()
    json_response(conn, 200, %{status: status})
  end

  def start(conn) do
    case Dust.Api.Service.start() do
      :ok ->
        json_response(conn, 200, %{ok: true})

      {:error, reason} ->
        json_response(conn, error_status(reason), %{error: format_reason(reason)})
    end
  end

  def stop(conn) do
    case Dust.Api.Service.stop() do
      :ok ->
        json_response(conn, 200, %{ok: true})

      {:error, reason} ->
        json_response(conn, error_status(reason), %{error: format_reason(reason)})
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  # 409 Conflict for "the caller's environment refuses this op declaratively"
  # so a NixOS user sees a distinct status code from a real failure.
  defp error_status(:nixos_managed), do: 409
  defp error_status(_), do: 500
end
