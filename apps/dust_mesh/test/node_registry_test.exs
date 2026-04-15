defmodule Dust.Mesh.NodeRegistryTest do
  use ExUnit.Case, async: false

  alias Dust.Mesh.NodeRegistry

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_registry! do
    start_supervised!({Registry, keys: :duplicate, name: Dust.Mesh.Registry})
    start_supervised!(NodeRegistry)
  end

  defp send_info(msg) do
    send(NodeRegistry, msg)
    # Give the GenServer a moment to process
    :sys.get_state(NodeRegistry)
  end

  setup_all do
    Application.stop(:dust_mesh)

    on_exit(fn -> Application.ensure_all_started(:dust_mesh) end)
  end

  setup do
    start_registry!()
    :ok
  end

  # ── list/0 ───────────────────────────────────────────────────────────────

  describe "list/0" do
    test "returns empty map when no peers have been seen" do
      assert NodeRegistry.list() == %{}
    end

    test "reflects entries after :nodeup" do
      send_info({:nodeup, :peer@host, []})

      registry = NodeRegistry.list()
      assert Map.has_key?(registry, :peer@host)
      assert registry[:peer@host].status == :online
    end
  end

  # ── online_nodes/0 ──────────────────────────────────────────────────────

  describe "online_nodes/0" do
    test "returns empty list when no peers are online" do
      assert NodeRegistry.online_nodes() == []
    end

    test "returns only online nodes after a mix of up/down" do
      send_info({:nodeup, :a@host, []})
      send_info({:nodeup, :b@host, []})
      send_info({:nodedown, :a@host, []})

      online = NodeRegistry.online_nodes()
      assert :b@host in online
      refute :a@host in online
    end
  end

  # ── status/1 ────────────────────────────────────────────────────────────

  describe "status/1" do
    test "returns :unknown for a never-seen node" do
      assert NodeRegistry.status(:never@host) == :unknown
    end

    test "returns :online after :nodeup" do
      send_info({:nodeup, :peer@host, []})
      assert NodeRegistry.status(:peer@host) == :online
    end

    test "returns :offline after :nodedown" do
      send_info({:nodeup, :peer@host, []})
      send_info({:nodedown, :peer@host, []})
      assert NodeRegistry.status(:peer@host) == :offline
    end
  end

  # ── :nodeup / :nodedown ─────────────────────────────────────────────────

  describe "nodeup/nodedown" do
    test "offline nodes are retained, not removed" do
      send_info({:nodeup, :peer@host, []})
      send_info({:nodedown, :peer@host, []})

      registry = NodeRegistry.list()
      assert Map.has_key?(registry, :peer@host)
      assert registry[:peer@host].status == :offline
    end

    test "a node can go online → offline → online again" do
      send_info({:nodeup, :peer@host, []})
      send_info({:nodedown, :peer@host, []})
      send_info({:nodeup, :peer@host, []})

      assert NodeRegistry.status(:peer@host) == :online
    end
  end

  # ── :presence message ───────────────────────────────────────────────────

  describe ":presence message" do
    test "marks a node as online" do
      send_info({:presence, :remote@host})

      assert NodeRegistry.status(:remote@host) == :online
    end
  end

  # ── :sync_request ───────────────────────────────────────────────────────

  describe ":sync_request" do
    test "handles sync_request without crashing and state is preserved" do
      send_info({:nodeup, :a@host, []})

      # A sync_request from node() causes the NodeRegistry to send
      # {:sync_response, Node.self(), registry} to {NodeRegistry, node()},
      # which loops back into itself. Verify the GenServer survives and
      # state is unchanged.
      send_info({:sync_request, node()})

      assert NodeRegistry.status(:a@host) == :online
    end

    test "handles sync_request from a remote node name" do
      send_info({:nodeup, :a@host, []})

      # When from_node is a remote node, send goes to {NodeRegistry, remote},
      # which is a no-op locally but the GenServer must not crash.
      send_info({:sync_request, :remote@host})

      assert NodeRegistry.status(:a@host) == :online
    end
  end

  # ── :sync_response (merge) ─────────────────────────────────────────────

  describe ":sync_response / merge_registries" do
    test "adds new nodes from peer registry" do
      their_registry = %{
        :new@host => %{status: :online, seen_at: DateTime.utc_now()}
      }

      send_info({:sync_response, :peer@host, their_registry})

      assert NodeRegistry.status(:new@host) == :online
    end

    test "local :online beats peer :offline" do
      send_info({:nodeup, :a@host, []})

      their_registry = %{
        :a@host => %{status: :offline, seen_at: DateTime.utc_now()}
      }

      send_info({:sync_response, :peer@host, their_registry})
      assert NodeRegistry.status(:a@host) == :online
    end

    test "peer :online beats local :offline" do
      send_info({:nodeup, :a@host, []})
      send_info({:nodedown, :a@host, []})

      their_registry = %{
        :a@host => %{status: :online, seen_at: DateTime.utc_now()}
      }

      send_info({:sync_response, :peer@host, their_registry})
      assert NodeRegistry.status(:a@host) == :online
    end

    test "both offline keeps the more recent seen_at" do
      old_time = ~U[2025-01-01 00:00:00Z]
      new_time = ~U[2026-01-01 00:00:00Z]

      # Seed local registry with an offline node at old_time
      local_offline = %{
        :a@host => %{status: :offline, seen_at: old_time}
      }

      send_info({:sync_response, :x@host, local_offline})

      # Now merge a peer registry with the same node at new_time
      their_registry = %{
        :a@host => %{status: :offline, seen_at: new_time}
      }

      send_info({:sync_response, :peer@host, their_registry})

      registry = NodeRegistry.list()
      assert registry[:a@host].seen_at == new_time
    end

    test "both offline keeps local when local is newer" do
      old_time = ~U[2025-01-01 00:00:00Z]
      new_time = ~U[2026-01-01 00:00:00Z]

      # Seed local registry with the newer entry
      local_offline = %{
        :a@host => %{status: :offline, seen_at: new_time}
      }

      send_info({:sync_response, :x@host, local_offline})

      their_registry = %{
        :a@host => %{status: :offline, seen_at: old_time}
      }

      send_info({:sync_response, :peer@host, their_registry})

      registry = NodeRegistry.list()
      assert registry[:a@host].seen_at == new_time
    end
  end

  # ── PubSub notifications ────────────────────────────────────────────────

  describe "pubsub notifications" do
    test "subscribers receive {:node_registry_changed, online_nodes}" do
      NodeRegistry.subscribe()

      send_info({:nodeup, :peer@host, []})

      assert_receive {:node_registry_changed, online_nodes}
      assert :peer@host in online_nodes
    end

    test "notification includes only online nodes" do
      NodeRegistry.subscribe()

      send_info({:nodeup, :a@host, []})
      send_info({:nodeup, :b@host, []})
      send_info({:nodedown, :a@host, []})

      # Drain intermediate messages and check last one
      online =
        receive_until_last(:node_registry_changed)

      assert :b@host in online
      refute :a@host in online
    end
  end

  # Drain the mailbox and return the payload of the last matching message
  defp receive_until_last(tag) do
    receive_until_last(tag, nil)
  end

  defp receive_until_last(tag, last) do
    receive do
      {^tag, payload} -> receive_until_last(tag, payload)
    after
      100 -> last
    end
  end
end
