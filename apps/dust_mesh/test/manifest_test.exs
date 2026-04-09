defmodule Dust.Mesh.ManifestTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Dust.Mesh.Manifest
  alias Dust.Mesh.Manifest.{FileIndex, ChunkIndex, ShardMap}
  alias Dust.Core.Crypto.{FileMeta, ChunkMeta}

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_manifest! do
    test_db_path = Dust.Utilities.File.mesh_db_dir()

    File.mkdir_p!(test_db_path)
    start_supervised!({Registry, keys: :duplicate, name: Dust.Mesh.Registry})
    start_supervised!({CubDB, data_dir: test_db_path, name: Dust.Mesh.Database})
    start_supervised!(Dust.Mesh.NodeRegistry)
    start_supervised!(FileIndex)
    start_supervised!(ChunkIndex)
    start_supervised!(ShardMap)
  end

  defp fake_encrypted_key, do: :crypto.strong_rand_bytes(64)

  defp make_chunk_meta(opts \\ []) do
    %ChunkMeta{
      hash: Keyword.get(opts, :hash, Base.encode16(:crypto.strong_rand_bytes(32))),
      size: Keyword.get(opts, :size, 4096),
      encrypted_chunk_key: Keyword.get(opts, :encrypted_chunk_key, fake_encrypted_key())
    }
  end

  defp make_file_meta do
    %FileMeta{encrypted_file_key: fake_encrypted_key()}
  end

  setup_all do
    Application.stop(:dust_mesh)

    on_exit(fn ->
      Application.ensure_all_started(:dust_mesh)
    end)
  end

  setup %{tmp_dir: tmp_dir} do
    old_env = Application.get_env(:dust_utilities, :config, %{})
    Application.put_env(:dust_utilities, :config, %{persist_dir: tmp_dir})
    start_manifest!()

    on_exit(fn ->
      if old_env do
        Application.put_env(:dust_utilities, :config, old_env)
      else
        Application.delete_env(:dust_utilities, :config)
      end
    end)

    :ok
  end

  # ── store_file_stream/3 ──────────────────────────────────────────────────

  describe "store_file_stream/3" do
    test "indexes a file and its chunks" do
      file_meta = make_file_meta()
      c1 = make_chunk_meta()
      c2 = make_chunk_meta()

      assert :ok = Manifest.store_file_stream("file-1", file_meta, [c1, c2])

      entry = FileIndex.get("file-1")
      assert entry.file_meta.encrypted_file_key == file_meta.encrypted_file_key
      assert length(entry.chunks) == 2
    end

    test "chunk IDs correspond to their content hash" do
      c1 = make_chunk_meta()
      c2 = make_chunk_meta()
      file_meta = make_file_meta()

      :ok = Manifest.store_file_stream("file-2", file_meta, [c1, c2])

      entry = FileIndex.get("file-2")
      assert entry.chunks == [c1.hash, c2.hash]
    end

    test "each chunk is stored in the ChunkIndex" do
      c1 = make_chunk_meta(size: 100)
      file_meta = make_file_meta()

      :ok = Manifest.store_file_stream("file-3", file_meta, [c1])

      chunk = ChunkIndex.get(c1.hash)
      assert chunk.chunk_meta.hash == c1.hash
      assert chunk.chunk_meta.size == 100
    end

    test "handles empty chunk stream" do
      file_meta = make_file_meta()
      assert :ok = Manifest.store_file_stream("empty", file_meta, [])

      entry = FileIndex.get("empty")
      assert entry.chunks == []
    end
  end

  # ── remove_file/1 ───────────────────────────────────────────────────────

  describe "remove_file/1" do
    test "removes a file and its chunks from both indices" do
      c1 = make_chunk_meta()
      file_meta = make_file_meta()

      :ok = Manifest.store_file_stream("file-rm", file_meta, [c1])

      assert :ok = Manifest.remove_file("file-rm")
      assert FileIndex.get("file-rm") == nil
      assert ChunkIndex.get(c1.encrypted_chunk_key) == nil
    end

    test "returns {:error, :not_found} for missing file" do
      assert {:error, :not_found} = Manifest.remove_file("nonexistent")
    end
  end

  # ── ChunkIndex ref counting ────────────────────────────────────────────

  # ── FileIndex CRUD ─────────────────────────────────────────────────────

  describe "FileIndex" do
    test "put, get, delete, and all" do
      entry = %{encrypted_file_key: fake_encrypted_key(), chunks: ["a", "b"]}
      FileIndex.put("f1", entry)

      assert FileIndex.get("f1") == entry
      assert Map.has_key?(FileIndex.all(), "f1")

      FileIndex.delete("f1")
      assert FileIndex.get("f1") == nil
    end

    test "get returns nil for missing key" do
      assert FileIndex.get("missing") == nil
    end
  end

  # ── Input validation ───────────────────────────────────────────────────

  describe "input validation" do
    test "store_file_stream raises FunctionClauseError for non-binary uuid" do
      assert_raise FunctionClauseError, fn ->
        Manifest.store_file_stream(123, make_file_meta(), [])
      end
    end

    test "remove_file raises FunctionClauseError for non-binary uuid" do
      assert_raise FunctionClauseError, fn ->
        Manifest.remove_file(nil)
      end
    end
  end

  # ── ShardMap ────────────────────────────────────────────────────────────

  describe "ShardMap" do
    test "put and get_shards" do
      assert :ok = ShardMap.put("chunk-abc", 0, :"dust@node-a")
      assert :ok = ShardMap.put("chunk-abc", 1, :"dust@node-b")
      assert :ok = ShardMap.put("chunk-abc", 2, :"dust@node-c")

      shards = ShardMap.get_shards("chunk-abc")
      assert map_size(shards) == 3
      assert :"dust@node-a" in shards[0].nodes
      assert :"dust@node-b" in shards[1].nodes
      assert :"dust@node-c" in shards[2].nodes
    end

    test "get_shards returns empty map for unknown chunk" do
      assert ShardMap.get_shards("nonexistent") == %{}
    end

    test "get_shards does not return entries from other chunks" do
      ShardMap.put("chunk-abc", 0, :"dust@node-a")
      ShardMap.put("chunk-def", 0, :"dust@node-b")

      abc_shards = ShardMap.get_shards("chunk-abc")
      assert map_size(abc_shards) == 1
      assert :"dust@node-a" in abc_shards[0].nodes
    end

    test "put adds multiple nodes to same shard" do
      ShardMap.put("chunk-abc", 0, :"dust@node-a")
      ShardMap.put("chunk-abc", 0, :"dust@node-b")

      shards = ShardMap.get_shards("chunk-abc")
      assert MapSet.size(shards[0].nodes) == 2
      assert :"dust@node-a" in shards[0].nodes
      assert :"dust@node-b" in shards[0].nodes
    end

    test "remove_node removes a node but keeps others" do
      ShardMap.put("chunk-abc", 0, :"dust@node-a")
      ShardMap.put("chunk-abc", 0, :"dust@node-b")

      assert :ok = ShardMap.remove_node("chunk-abc", 0, :"dust@node-a")

      shards = ShardMap.get_shards("chunk-abc")
      assert MapSet.size(shards[0].nodes) == 1
      assert :"dust@node-b" in shards[0].nodes
    end

    test "remove_node deletes entry when last node removed" do
      ShardMap.put("chunk-abc", 0, :"dust@node-a")
      assert :ok = ShardMap.remove_node("chunk-abc", 0, :"dust@node-a")
      assert ShardMap.get_shards("chunk-abc") == %{}
    end

    test "remove_node no-ops for nonexistent entry" do
      assert :ok = ShardMap.remove_node("chunk-abc", 0, :"dust@node-a")
    end

    test "delete removes a single shard" do
      ShardMap.put("chunk-abc", 0, :"dust@node-a")
      ShardMap.put("chunk-abc", 1, :"dust@node-b")

      assert :ok = ShardMap.delete("chunk-abc", 0)

      shards = ShardMap.get_shards("chunk-abc")
      assert map_size(shards) == 1
      assert :"dust@node-b" in shards[1].nodes
    end

    test "delete_shards removes all entries for a chunk" do
      for i <- 0..5 do
        ShardMap.put("chunk-abc", i, :"dust@node-#{i}")
      end

      assert :ok = ShardMap.delete_shards("chunk-abc", 6)
      assert ShardMap.get_shards("chunk-abc") == %{}
    end
  end

  # ── Manifest shard integration ──────────────────────────────────────────

  describe "Manifest shard integration" do
    test "store_shards and get_shard_locations" do
      placements = [{0, :dust@a}, {1, :dust@b}, {2, :dust@c}]
      assert :ok = Manifest.store_shards("chunk-xyz", placements)

      locations = Manifest.get_shard_locations("chunk-xyz")
      assert map_size(locations) == 3
      assert :dust@a in locations[0].nodes
      assert :dust@c in locations[2].nodes
    end

    test "remove_file cleans up shard entries for dereferenced chunks" do
      c1 = make_chunk_meta()
      file_meta = make_file_meta()
      :ok = Manifest.store_file_stream("file-shard", file_meta, [c1])

      # Simulate shard placements
      for i <- 0..5 do
        ShardMap.put(c1.hash, i, :"dust@node-#{i}")
      end

      assert map_size(ShardMap.get_shards(c1.hash)) == 6

      :ok = Manifest.remove_file("file-shard")

      assert ShardMap.get_shards(c1.hash) == %{}
    end

    test "remove_file preserves shard entries when chunk still referenced" do
      # Same chunk used by two files (deduplication)
      shared_hash = Base.encode16(:crypto.strong_rand_bytes(32))
      c1 = make_chunk_meta(hash: shared_hash)
      file_meta = make_file_meta()

      :ok = Manifest.store_file_stream("file-1", file_meta, [c1])
      :ok = Manifest.store_file_stream("file-2", file_meta, [c1])

      for i <- 0..5 do
        ShardMap.put(shared_hash, i, :"dust@node-#{i}")
      end

      # Remove first file — chunk ref_count drops to 1, shards should remain
      :ok = Manifest.remove_file("file-1")

      assert ChunkIndex.get(shared_hash) != nil
      assert map_size(ShardMap.get_shards(shared_hash)) == 6

      # Remove second file — chunk fully dereferenced, shards cleaned up
      :ok = Manifest.remove_file("file-2")

      assert ChunkIndex.get(shared_hash) == nil
      assert ShardMap.get_shards(shared_hash) == %{}
    end
  end
end
