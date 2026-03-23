defmodule TestSharedMap do
  @moduledoc "A concrete module using SharedMap for testing."
  use Dust.Mesh.SharedMap

  # Expose the private crdt_* helpers as public API for testing
  def put(key, value), do: crdt_put(key, value)
  def get(key), do: crdt_get(key)
  def delete(key), do: crdt_delete(key)
  def to_map, do: crdt_to_map()
end

defmodule Dust.Mesh.SharedMapTest do
  use ExUnit.Case, async: false

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_deps! do
    data_dir =
      "/tmp/dust_mesh_test_data/test_#{:os.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"

    File.mkdir_p!(data_dir)
    start_supervised!({Registry, keys: :duplicate, name: Dust.Mesh.Registry})
    start_supervised!({CubDB, data_dir: data_dir, name: Dust.Mesh.Database})
    start_supervised!(Dust.Mesh.NodeRegistry)
  end

  defp start_shared_map! do
    start_deps!()
    start_supervised!(TestSharedMap)
  end

  # ── child_spec/1 ────────────────────────────────────────────────────────

  describe "child_spec/1" do
    test "returns spec with :supervisor type" do
      spec = TestSharedMap.child_spec([])
      assert spec.type == :supervisor
      assert spec.id == TestSharedMap
    end
  end

  # ── start_link / supervision tree ──────────────────────────────────────

  describe "start_link/1" do
    test "starts a supervision tree with CRDT and GenServer children" do
      start_shared_map!()

      # The supervisor should be running
      supervisor_name = :"Elixir.TestSharedMap.Supervisor"
      assert Process.whereis(supervisor_name) != nil

      # The GenServer should be running
      assert Process.whereis(TestSharedMap) != nil
    end
  end

  # ── CRDT helpers ────────────────────────────────────────────────────────

  describe "crdt_put/get/delete/to_map" do
    test "put and get a value" do
      start_shared_map!()

      TestSharedMap.put(:key1, "value1")
      assert TestSharedMap.get(:key1) == "value1"
    end

    test "get returns nil for missing key" do
      start_shared_map!()
      assert TestSharedMap.get(:nonexistent) == nil
    end

    test "delete removes a key" do
      start_shared_map!()

      TestSharedMap.put(:key1, "value1")
      TestSharedMap.delete(:key1)
      assert TestSharedMap.get(:key1) == nil
    end

    test "to_map returns all entries" do
      start_shared_map!()

      TestSharedMap.put(:a, 1)
      TestSharedMap.put(:b, 2)

      map = TestSharedMap.to_map()
      assert map[:a] == 1
      assert map[:b] == 2
    end

    test "put overwrites existing value" do
      start_shared_map!()

      TestSharedMap.put(:key, "old")
      TestSharedMap.put(:key, "new")
      assert TestSharedMap.get(:key) == "new"
    end
  end

  # ── :node_registry_changed handling ────────────────────────────────────

  describe ":node_registry_changed" do
    test "handles node_registry_changed message without error" do
      start_shared_map!()

      # Simulate a node_registry_changed message
      send(TestSharedMap, {:node_registry_changed, [:peer@host]})

      # The GenServer should still be alive after handling the message
      :sys.get_state(TestSharedMap)
      assert Process.whereis(TestSharedMap) != nil
    end

    test "handles empty online_nodes list" do
      start_shared_map!()

      send(TestSharedMap, {:node_registry_changed, []})

      :sys.get_state(TestSharedMap)
      assert Process.whereis(TestSharedMap) != nil
    end

    test "logs warning for unexpected message and stays alive" do
      start_shared_map!()

      send(TestSharedMap, {:totally_unexpected, :data})

      :sys.get_state(TestSharedMap)
      assert Process.whereis(TestSharedMap) != nil
    end
  end
end
