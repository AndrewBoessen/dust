defmodule Dust.Ui.SessionController do
  @moduledoc """
  Login / logout for the Dust web UI.

  Authentication is "you know the keystore password" — the controller
  delegates to `Dust.Ui.Auth.Keystore` which wraps `Dust.Core.KeyStore`.
  """
  use Dust.Ui, :controller

  alias Dust.Ui.Auth.{Keystore, Session}

  def new(conn, _params) do
    render(conn, :new,
      error: nil,
      system_ready?: Dust.Daemon.Readiness.ready?(),
      layout: false
    )
  end

  def create(conn, %{"password" => password}) do
    case Keystore.unlock(password) do
      :ok ->
        conn
        |> Session.log_in()
        |> put_flash(:info, "Welcome back.")
        |> redirect(to: ~p"/")

      {:error, :invalid_password} ->
        conn
        |> put_flash(:error, "Invalid password.")
        |> render(:new,
          error: "Invalid password.",
          system_ready?: Dust.Daemon.Readiness.ready?(),
          layout: false
        )

      {:error, reason} ->
        conn
        |> put_flash(:error, "Could not unlock keystore: #{inspect(reason)}.")
        |> render(:new,
          error: "Could not unlock keystore.",
          system_ready?: Dust.Daemon.Readiness.ready?(),
          layout: false
        )
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Password is required.")
    |> render(:new,
      error: "Password is required.",
      system_ready?: Dust.Daemon.Readiness.ready?(),
      layout: false
    )
  end

  def delete(conn, _params) do
    _ = Keystore.lock()

    conn
    |> Session.log_out()
    |> put_flash(:info, "Locked.")
    |> redirect(to: ~p"/login")
  end
end
