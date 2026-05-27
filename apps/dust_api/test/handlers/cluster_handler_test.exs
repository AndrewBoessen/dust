defmodule Dust.Api.Handlers.ClusterHandlerTest do
  use ExUnit.Case, async: false

  import Mox
  import Plug.Test

  alias Dust.Api.Handlers.ClusterHandler

  setup :verify_on_exit!

  describe "create_invite/1" do
    test "returns 201 with the sidecar's Tailscale self_ip as join_ip" do
      expect(Dust.Bridge.Mock, :auth_status, fn ->
        {:ok, %{state: "authenticated", self_ip: "100.64.0.5", auth_url: ""}}
      end)

      expect(Dust.Bridge.Mock, :create_invite, fn -> {:ok, "deadbeef"} end)

      conn =
        conn(:post, "/api/v1/invite")
        |> ClusterHandler.create_invite()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["join_ip"] == "100.64.0.5"
      assert body["token"] == "deadbeef"
    end

    test "returns 503 when the node has no Tailscale IP yet" do
      expect(Dust.Bridge.Mock, :auth_status, fn ->
        {:ok, %{state: "needs_login", self_ip: "", auth_url: "https://login.tailscale.com/x"}}
      end)

      conn =
        conn(:post, "/api/v1/invite")
        |> ClusterHandler.create_invite()

      assert conn.status == 503
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "tailscale_not_ready"
    end

    test "returns 500 when auth_status fails" do
      expect(Dust.Bridge.Mock, :auth_status, fn -> {:error, :timeout} end)

      conn =
        conn(:post, "/api/v1/invite")
        |> ClusterHandler.create_invite()

      assert conn.status == 500
    end
  end
end
