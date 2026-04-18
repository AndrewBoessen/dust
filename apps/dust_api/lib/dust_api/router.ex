defmodule Dust.Api.Router do
  @moduledoc """
  Top-level Plug router for the Dust API.

  All endpoints are JSON-based except for WebSocket upgrades.
  Authentication is enforced via `Dust.Api.Auth.Plug` (bearer token).
  """

  use Plug.Router

  plug Plug.Logger, log: :debug

  plug Plug.Parsers,
    parsers: [:json, :multipart, :urlencoded],
    pass: ["*/*"],
    json_decoder: Jason

  plug Dust.Api.Auth.Plug

  plug :match
  plug :dispatch

  # ── Status ─────────────────────────────────────────────────────────────

  get "/api/v1/status" do
    Dust.Api.Handlers.StatusHandler.handle(conn)
  end

  # ── KeyStore ───────────────────────────────────────────────────────────

  post "/api/v1/unlock" do
    Dust.Api.Handlers.KeystoreHandler.unlock(conn)
  end

  post "/api/v1/lock" do
    Dust.Api.Handlers.KeystoreHandler.lock(conn)
  end

  # ── File System ────────────────────────────────────────────────────────

  get "/api/v1/fs/ls/:dir_id" do
    Dust.Api.Handlers.FsHandler.list(conn, dir_id)
  end

  post "/api/v1/fs/mkdir" do
    Dust.Api.Handlers.FsHandler.mkdir(conn)
  end

  post "/api/v1/fs/upload" do
    Dust.Api.Handlers.FsHandler.upload(conn)
  end

  post "/api/v1/fs/download" do
    Dust.Api.Handlers.FsHandler.download(conn)
  end

  delete "/api/v1/fs/rm/:id" do
    Dust.Api.Handlers.FsHandler.remove(conn, id)
  end

  # ── Cluster ────────────────────────────────────────────────────────────

  get "/api/v1/nodes" do
    Dust.Api.Handlers.ClusterHandler.list_nodes(conn)
  end

  post "/api/v1/invite" do
    Dust.Api.Handlers.ClusterHandler.create_invite(conn)
  end

  post "/api/v1/join" do
    Dust.Api.Handlers.ClusterHandler.join(conn)
  end

  # ── Configuration ──────────────────────────────────────────────────────

  get "/api/v1/config" do
    Dust.Api.Handlers.ConfigHandler.get_config(conn)
  end

  put "/api/v1/config" do
    Dust.Api.Handlers.ConfigHandler.update_config(conn)
  end

  # ── Garbage Collection ─────────────────────────────────────────────────

  get "/api/v1/gc/stats" do
    Dust.Api.Handlers.GcHandler.stats(conn)
  end

  post "/api/v1/gc/sweep" do
    Dust.Api.Handlers.GcHandler.sweep(conn)
  end

  # ── WebSocket Events ───────────────────────────────────────────────────

  get "/api/v1/ws/events" do
    conn
    |> WebSockAdapter.upgrade(Dust.Api.EventStream, [], timeout: 60_000)
    |> halt()
  end

  # ── Catch-all ──────────────────────────────────────────────────────────

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
  end
end
