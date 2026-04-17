defmodule Dust.Api.Handlers.ClusterHandler do
  @moduledoc """
  Handles cluster management operations:

    - `GET  /api/v1/nodes`  — list cluster peers and their fitness scores
    - `POST /api/v1/invite` — create an invite token for a new node
    - `POST /api/v1/join`   — join an existing cluster via invite
  """

  import Plug.Conn

  alias Dust.Mesh.NodeRegistry

  @doc "List all known cluster nodes with their online status and fitness."
  @spec list_nodes(Plug.Conn.t()) :: Plug.Conn.t()
  def list_nodes(conn) do
    online_nodes = NodeRegistry.online_nodes()

    nodes =
      Enum.map([node() | Node.list()], fn n ->
        %{
          name: to_string(n),
          online: n == node() or n in online_nodes,
          fitness: get_fitness(n),
          self: n == node()
        }
      end)

    json_response(conn, 200, %{nodes: nodes})
  end

  @doc "Create an invite token for a new node to join the cluster."
  @spec create_invite(Plug.Conn.t()) :: Plug.Conn.t()
  def create_invite(conn) do
    case bridge_module().create_invite() do
      {:ok, token} ->
        # Get this node's Tailscale IP for the joiner to connect to
        self_ip =
          node()
          |> to_string()
          |> String.split("@")
          |> List.last()

        json_response(conn, 201, %{
          token: token,
          join_ip: self_ip,
          message: "Use this token and IP to join the cluster"
        })

      {:error, reason} ->
        json_response(conn, 500, %{error: inspect(reason)})
    end
  end

  @doc "Join an existing cluster using a peer address and invite token."
  @spec join(Plug.Conn.t()) :: Plug.Conn.t()
  def join(conn) do
    case conn.body_params do
      %{"peer_address" => peer_address, "token" => token} ->
        case bridge_module().join(peer_address, token) do
          {:ok, _master_key, _otp_cookie} ->
            json_response(conn, 200, %{status: "joined", peer: peer_address})

          {:error, reason} ->
            json_response(conn, 400, %{error: inspect(reason)})
        end

      _ ->
        json_response(conn, 400, %{
          error: "missing_fields",
          message: "'peer_address' and 'token' are required"
        })
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp get_fitness(target_node) do
    try do
      Dust.Core.Fitness.score(target_node)
    rescue
      _ -> 0.0
    end
  end

  defp bridge_module do
    Application.get_env(:dust_bridge, :bridge_module, Dust.Bridge)
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
