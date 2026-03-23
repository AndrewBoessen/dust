defmodule Dust.Mesh.ManifestTest do
  use ExUnit.Case, async: false

  alias Dust.Mesh.Manifest
  alias Dust.Mesh.Manifest.{FileIndex, ChunkIndex}
  alias Dust.Core.Crypto.{FileMeta, ChunkMeta}

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_manifest! do
    data_dir =
      "/tmp/dust_mesh_test_data/test_#{:os.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"

    File.mkdir_p!(data_dir)
    start_supervised!({Registry, keys: :duplicate, name: Dust.Mesh.Registry})
    start_supervised!({CubDB, data_dir: data_dir, name: Dust.Mesh.Database})
    start_supervised!(Dust.Mesh.NodeRegistry)
    start_supervised!(FileIndex)
    start_supervised!(ChunkIndex)
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

  # ── store_file_stream/3 ──────────────────────────────────────────────────

  describe "store_file_stream/3" do
    test "indexes a file and its chunks" do
      start_manifest!()

      file_meta = make_file_meta()
      c1 = make_chunk_meta()
      c2 = make_chunk_meta()

      assert :ok = Manifest.store_file_stream("file-1", file_meta, [c1, c2])

      entry = FileIndex.get("file-1")
      assert entry.file_meta.encrypted_file_key == file_meta.encrypted_file_key
      assert length(entry.chunks) == 2
    end

    test "chunk IDs correspond to their content hash" do
      start_manifest!()

      c1 = make_chunk_meta()
      c2 = make_chunk_meta()
      file_meta = make_file_meta()

      :ok = Manifest.store_file_stream("file-2", file_meta, [c1, c2])

      entry = FileIndex.get("file-2")
      assert entry.chunks == [c1.hash, c2.hash]
    end

    test "each chunk is stored in the ChunkIndex" do
      start_manifest!()

      c1 = make_chunk_meta(size: 100)
      file_meta = make_file_meta()

      :ok = Manifest.store_file_stream("file-3", file_meta, [c1])

      chunk = ChunkIndex.get(c1.hash)
      assert chunk.chunk_meta.hash == c1.hash
      assert chunk.chunk_meta.size == 100
      assert chunk.ref_count == 1
    end

    test "handles empty chunk stream" do
      start_manifest!()

      file_meta = make_file_meta()
      assert :ok = Manifest.store_file_stream("empty", file_meta, [])

      entry = FileIndex.get("empty")
      assert entry.chunks == []
    end
  end

  # ── remove_file/1 ───────────────────────────────────────────────────────

  describe "remove_file/1" do
    test "removes a file and its chunks from both indices" do
      start_manifest!()

      c1 = make_chunk_meta()
      file_meta = make_file_meta()

      :ok = Manifest.store_file_stream("file-rm", file_meta, [c1])

      assert :ok = Manifest.remove_file("file-rm")
      assert FileIndex.get("file-rm") == nil
      assert ChunkIndex.get(c1.encrypted_chunk_key) == nil
    end

    test "returns {:error, :not_found} for missing file" do
      start_manifest!()
      assert {:error, :not_found} = Manifest.remove_file("nonexistent")
    end
  end

  # ── ChunkIndex ref counting ────────────────────────────────────────────

  describe "ChunkIndex ref counting" do
    test "increments ref_count on duplicate put" do
      start_manifest!()

      key = fake_encrypted_key()
      entry = %{hash: "abc", size: 10, ref_count: 1}

      ChunkIndex.put(key, entry)
      assert ChunkIndex.get(key).ref_count == 1

      ChunkIndex.put(key, entry)
      assert ChunkIndex.get(key).ref_count == 2
    end

    test "delete decrements ref_count when > 1" do
      start_manifest!()

      key = fake_encrypted_key()
      entry = %{hash: "abc", size: 10, ref_count: 1}

      ChunkIndex.put(key, entry)
      ChunkIndex.put(key, entry)
      assert ChunkIndex.get(key).ref_count == 2

      ChunkIndex.delete(key)
      assert ChunkIndex.get(key).ref_count == 1
    end

    test "delete removes entry when ref_count reaches zero" do
      start_manifest!()

      key = fake_encrypted_key()
      entry = %{hash: "abc", size: 10, ref_count: 1}

      ChunkIndex.put(key, entry)
      ChunkIndex.delete(key)
      assert ChunkIndex.get(key) == nil
    end

    test "delete no-ops for missing key" do
      start_manifest!()
      assert :ok = ChunkIndex.delete("nonexistent")
    end
  end

  # ── FileIndex CRUD ─────────────────────────────────────────────────────

  describe "FileIndex" do
    test "put, get, delete, and all" do
      start_manifest!()

      entry = %{encrypted_file_key: fake_encrypted_key(), chunks: ["a", "b"]}
      FileIndex.put("f1", entry)

      assert FileIndex.get("f1") == entry
      assert Map.has_key?(FileIndex.all(), "f1")

      FileIndex.delete("f1")
      assert FileIndex.get("f1") == nil
    end

    test "get returns nil for missing key" do
      start_manifest!()
      assert FileIndex.get("missing") == nil
    end
  end

  # ── Input validation ───────────────────────────────────────────────────

  describe "input validation" do
    test "store_file_stream raises FunctionClauseError for non-binary uuid" do
      start_manifest!()

      assert_raise FunctionClauseError, fn ->
        Manifest.store_file_stream(123, make_file_meta(), [])
      end
    end

    test "remove_file raises FunctionClauseError for non-binary uuid" do
      start_manifest!()

      assert_raise FunctionClauseError, fn ->
        Manifest.remove_file(nil)
      end
    end
  end
end
