defmodule Dust.Ui.Auth.Session do
  @moduledoc """
  Session helpers and plugs for UI authentication.

  Authentication is bound to the keystore: a user is considered logged in
  while the session carries `:authenticated` AND the keystore reports
  `Dust.Ui.Auth.Keystore.unlocked?/0`. If the keystore is locked from
  another source (CLI, API), the next request bounces back to `/login`.
  """

  import Plug.Conn
  use Phoenix.VerifiedRoutes,
    endpoint: Dust.Ui.Endpoint,
    router: Dust.Ui.Router,
    statics: Dust.Ui.static_paths()

  @session_key :authenticated

  @doc "Marks the connection as logged in after a successful unlock."
  @spec log_in(Plug.Conn.t()) :: Plug.Conn.t()
  def log_in(conn) do
    conn
    |> renew_session()
    |> put_session(@session_key, true)
  end

  @doc "Clears any authentication state from the session."
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    conn
    |> configure_session(drop: true)
  end

  @doc "Returns true if the session is authenticated and the keystore is unlocked."
  @spec authenticated?(Plug.Conn.t()) :: boolean()
  def authenticated?(conn) do
    get_session(conn, @session_key) == true and Dust.Ui.Auth.Keystore.unlocked?()
  end

  # ── Plug behaviour ───────────────────────────────────────────────────

  @doc false
  def init(action) when action in [:require_authenticated, :redirect_if_authenticated],
    do: action

  @doc false
  def call(conn, :require_authenticated), do: require_authenticated(conn, [])
  def call(conn, :redirect_if_authenticated), do: redirect_if_authenticated(conn, [])

  # ── Plug actions ─────────────────────────────────────────────────────

  @doc "Plug: redirect to /login if the session is not authenticated."
  def require_authenticated(conn, _opts) do
    if authenticated?(conn) do
      conn
    else
      conn
      |> log_out()
      |> Phoenix.Controller.redirect(to: ~p"/login")
      |> halt()
    end
  end

  @doc """
  Plug: redirect already-authenticated visitors away from the login page.
  """
  def redirect_if_authenticated(conn, _opts) do
    if authenticated?(conn) do
      conn
      |> Phoenix.Controller.redirect(to: ~p"/")
      |> halt()
    else
      conn
    end
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
