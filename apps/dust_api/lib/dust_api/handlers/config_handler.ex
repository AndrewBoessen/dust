defmodule Dust.Api.Handlers.ConfigHandler do
  @moduledoc """
  Handles configuration operations:

    - `GET /api/v1/config` — read the current configuration
    - `PUT /api/v1/config` — update runtime-mutable configuration keys
  """

  import Plug.Conn

  alias Dust.Utilities.Config

  @doc "Returns the current configuration as JSON."
  @spec get_config(Plug.Conn.t()) :: Plug.Conn.t()
  def get_config(conn) do
    config =
      Config.all()
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

    json_response(conn, 200, %{config: config})
  end

  @doc """
  Updates one or more runtime-mutable configuration keys.

  Expects a JSON body with key-value pairs to update.
  Boot-only keys (`persist_dir`, `erasure_k`, `erasure_m`) will be rejected.

  ## Example request body

      {"replication_factor": 3, "disk_quota_bytes": 100000000000}
  """
  @spec update_config(Plug.Conn.t()) :: Plug.Conn.t()
  def update_config(conn) do
    updates = conn.body_params

    if map_size(updates) == 0 do
      json_response(conn, 400, %{
        error: "empty_body",
        message: "Provide key-value pairs to update"
      })
    else
      results =
        Enum.map(updates, fn {key_str, value} ->
          key = safe_to_atom(key_str)

          if key do
            case Config.put(key, value) do
              :ok -> {key_str, "ok"}
              {:error, reason} -> {key_str, %{error: inspect(reason)}}
            end
          else
            {key_str, %{error: "unknown_key"}}
          end
        end)
        |> Enum.into(%{})

      has_errors = Enum.any?(results, fn {_, v} -> is_map(v) end)
      status = if has_errors, do: 207, else: 200

      json_response(conn, status, %{results: results})
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp safe_to_atom(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> nil
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
