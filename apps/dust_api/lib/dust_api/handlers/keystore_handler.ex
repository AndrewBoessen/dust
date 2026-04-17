defmodule Dust.Api.Handlers.KeystoreHandler do
  @moduledoc """
  Handles KeyStore operations:

    - `POST /api/v1/unlock` — unlock with password
    - `POST /api/v1/lock`   — lock the key store
  """

  import Plug.Conn

  @doc "Unlock the KeyStore with the provided password."
  @spec unlock(Plug.Conn.t()) :: Plug.Conn.t()
  def unlock(conn) do
    case conn.body_params do
      %{"password" => password} when is_binary(password) and password != "" ->
        case Dust.Core.KeyStore.unlock(password) do
          :ok ->
            json_response(conn, 200, %{status: "unlocked"})

          {:error, :decrypt_failed} ->
            json_response(conn, 401, %{error: "invalid_password"})

          {:error, :already_unlocked} ->
            json_response(conn, 200, %{status: "already_unlocked"})

          {:error, reason} ->
            json_response(conn, 500, %{error: inspect(reason)})
        end

      _ ->
        json_response(conn, 400, %{error: "missing_password", message: "Field 'password' is required"})
    end
  end

  @doc "Lock the KeyStore."
  @spec lock(Plug.Conn.t()) :: Plug.Conn.t()
  def lock(conn) do
    :ok = Dust.Core.KeyStore.lock()
    json_response(conn, 200, %{status: "locked"})
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
