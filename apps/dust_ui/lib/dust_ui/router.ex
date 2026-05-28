defmodule Dust.Ui.Router do
  use Dust.Ui, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Dust.Ui.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_auth do
    plug Dust.Ui.Auth.Session, :require_authenticated
  end

  pipeline :redirect_if_authed do
    plug Dust.Ui.Auth.Session, :redirect_if_authenticated
  end

  scope "/", Dust.Ui do
    pipe_through :browser

    scope "/" do
      pipe_through :redirect_if_authed
      get "/login", SessionController, :new
      post "/login", SessionController, :create
    end

    delete "/logout", SessionController, :delete

    scope "/" do
      pipe_through :require_auth

      live_session :authenticated, on_mount: [Dust.Ui.Auth.LiveAuth] do
        live "/", IndexLive, :show
        live "/files", FilesLive, :root
        live "/files/:dir_id", FilesLive, :show
        live "/peers", PeersLive, :show
        live "/storage", StorageLive, :show
      end

      get "/download/:file_id", DownloadController, :show
    end
  end
end
