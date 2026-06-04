defmodule Dust.Ui.Auth.LiveAuth do
  @moduledoc """
  LiveView `on_mount` hook that enforces an authenticated session.

  Used in a `live_session` block in the router. Halts the mount and
  redirects to `/login` when:

    * the session does not carry `:authenticated`, OR
    * the keystore has been locked out of band (CLI / API).
  """

  import Phoenix.LiveView
  use Phoenix.VerifiedRoutes,
    endpoint: Dust.Ui.Endpoint,
    router: Dust.Ui.Router,
    statics: Dust.Ui.static_paths()

  def on_mount(:default, _params, session, socket) do
    if session["authenticated"] == true and Dust.Ui.Auth.Keystore.unlocked?() do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: ~p"/login")}
    end
  end
end
