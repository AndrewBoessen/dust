defmodule Dust.Mesh.FileSystemTest do
  use ExUnit.Case, async: false

  alias Dust.Mesh.FileSystem

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_file_system! do
    start_supervised!({Registry, keys: :duplicate, name: Dust.Mesh.Registry})
    start_supervised!(Dust.Mesh.NodeRegistry)
    start_supervised!(Dust.Mesh.FileSystem.DirMap)
    start_supervised!(Dust.Mesh.FileSystem.FileMap)
  end

  # ── mkdir/2 ──────────────────────────────────────────────────────────────

  describe "mkdir/2" do
    test "creates a root directory with nil parent" do
      start_file_system!()

      assert {:ok, id} = FileSystem.mkdir(nil, "root")
      assert is_binary(id)

      entry = FileSystem.get_dir(id)
      assert entry.name == "root"
      assert entry.dirs == MapSet.new()
      assert entry.files == MapSet.new()
      assert %DateTime{} = entry.created_at
    end

    test "creates a child directory under a parent" do
      start_file_system!()

      {:ok, parent_id} = FileSystem.mkdir(nil, "parent")
      {:ok, child_id} = FileSystem.mkdir(parent_id, "child")

      parent = FileSystem.get_dir(parent_id)
      assert MapSet.member?(parent.dirs, child_id)

      child = FileSystem.get_dir(child_id)
      assert child.name == "child"
    end
  end

  # ── get_dir/1 ────────────────────────────────────────────────────────────

  describe "get_dir/1" do
    test "returns entry for existing directory" do
      start_file_system!()
      {:ok, id} = FileSystem.mkdir(nil, "docs")

      entry = FileSystem.get_dir(id)
      assert entry.name == "docs"
    end

    test "returns nil for non-existent directory" do
      start_file_system!()
      assert FileSystem.get_dir("nonexistent") == nil
    end
  end

  # ── ls/1 ─────────────────────────────────────────────────────────────────

  describe "ls/1" do
    test "lists child directories and files" do
      start_file_system!()

      {:ok, root} = FileSystem.mkdir(nil, "root")
      {:ok, sub} = FileSystem.mkdir(root, "sub")
      {:ok, file} = FileSystem.put_file(root, "readme.md", %{size: 42})

      result = FileSystem.ls(root)
      assert is_list(result.dirs)
      assert is_list(result.files)

      dir_ids = Enum.map(result.dirs, & &1.id)
      assert sub in dir_ids

      file_ids = Enum.map(result.files, & &1.id)
      assert file in file_ids
    end

    test "returns {:error, :not_found} for missing directory" do
      start_file_system!()
      assert {:error, :not_found} = FileSystem.ls("missing")
    end

    test "returns empty lists for directory with no children" do
      start_file_system!()
      {:ok, id} = FileSystem.mkdir(nil, "empty")

      assert %{dirs: [], files: []} = FileSystem.ls(id)
    end
  end

  # ── rename_dir/2 ─────────────────────────────────────────────────────────

  describe "rename_dir/2" do
    test "renames a directory in place" do
      start_file_system!()
      {:ok, id} = FileSystem.mkdir(nil, "old_name")

      :ok = FileSystem.rename_dir(id, "new_name")

      assert FileSystem.get_dir(id).name == "new_name"
    end

    test "returns {:error, :not_found} for missing directory" do
      start_file_system!()
      assert {:error, :not_found} = FileSystem.rename_dir("missing", "x")
    end
  end

  # ── rmdir/2 ──────────────────────────────────────────────────────────────

  describe "rmdir/2" do
    test "removes an empty directory" do
      start_file_system!()
      {:ok, parent} = FileSystem.mkdir(nil, "parent")
      {:ok, child} = FileSystem.mkdir(parent, "child")

      assert :ok = FileSystem.rmdir(child, parent)
      assert FileSystem.get_dir(child) == nil

      parent_entry = FileSystem.get_dir(parent)
      refute MapSet.member?(parent_entry.dirs, child)
    end

    test "removes a root directory with nil parent" do
      start_file_system!()
      {:ok, id} = FileSystem.mkdir(nil, "root")

      assert :ok = FileSystem.rmdir(id, nil)
      assert FileSystem.get_dir(id) == nil
    end

    test "returns {:error, :not_empty} if directory has child dirs" do
      start_file_system!()
      {:ok, parent} = FileSystem.mkdir(nil, "parent")
      {:ok, _child} = FileSystem.mkdir(parent, "child")

      assert {:error, :not_empty} = FileSystem.rmdir(parent, nil)
    end

    test "returns {:error, :not_empty} if directory has files" do
      start_file_system!()
      {:ok, dir} = FileSystem.mkdir(nil, "dir")
      {:ok, _file} = FileSystem.put_file(dir, "file.txt")

      assert {:error, :not_empty} = FileSystem.rmdir(dir, nil)
    end

    test "returns {:error, :not_found} for missing directory" do
      start_file_system!()
      assert {:error, :not_found} = FileSystem.rmdir("missing", nil)
    end
  end

  # ── put_file/3 ───────────────────────────────────────────────────────────

  describe "put_file/3" do
    test "adds a file to a directory" do
      start_file_system!()
      {:ok, dir} = FileSystem.mkdir(nil, "docs")

      assert {:ok, file_id} = FileSystem.put_file(dir, "notes.txt", %{size: 100})
      assert is_binary(file_id)

      dir_entry = FileSystem.get_dir(dir)
      assert MapSet.member?(dir_entry.files, file_id)
    end

    test "automatically sets :name and :created_at in metadata" do
      start_file_system!()
      {:ok, dir} = FileSystem.mkdir(nil, "docs")
      {:ok, file_id} = FileSystem.put_file(dir, "readme.md", %{mime: "text/plain"})

      meta = FileSystem.stat(file_id)
      assert meta.name == "readme.md"
      assert meta.mime == "text/plain"
      assert %DateTime{} = meta.created_at
    end

    test "returns {:error, :dir_not_found} for non-existent directory" do
      start_file_system!()
      assert {:error, :dir_not_found} = FileSystem.put_file("missing", "f.txt")
    end
  end

  # ── stat/1 ───────────────────────────────────────────────────────────────

  describe "stat/1" do
    test "returns metadata with :id for existing file" do
      start_file_system!()
      {:ok, dir} = FileSystem.mkdir(nil, "d")
      {:ok, fid} = FileSystem.put_file(dir, "f.txt", %{size: 5})

      meta = FileSystem.stat(fid)
      assert meta.id == fid
      assert meta.name == "f.txt"
      assert meta.size == 5
    end

    test "returns nil for non-existent file" do
      start_file_system!()
      assert FileSystem.stat("missing") == nil
    end
  end

  # ── update_file/2 ───────────────────────────────────────────────────────

  describe "update_file/2" do
    test "merges updates into existing metadata" do
      start_file_system!()
      {:ok, dir} = FileSystem.mkdir(nil, "d")
      {:ok, fid} = FileSystem.put_file(dir, "f.txt", %{size: 10})

      assert :ok = FileSystem.update_file(fid, %{size: 20, mime: "text/plain"})

      meta = FileSystem.stat(fid)
      assert meta.size == 20
      assert meta.mime == "text/plain"
      assert meta.name == "f.txt"
    end

    test "returns {:error, :not_found} for missing file" do
      start_file_system!()
      assert {:error, :not_found} = FileSystem.update_file("missing", %{size: 0})
    end
  end

  # ── mv_file/3 ───────────────────────────────────────────────────────────

  describe "mv_file/3" do
    test "moves a file between directories" do
      start_file_system!()
      {:ok, src} = FileSystem.mkdir(nil, "src")
      {:ok, dst} = FileSystem.mkdir(nil, "dst")
      {:ok, fid} = FileSystem.put_file(src, "f.txt")

      assert :ok = FileSystem.mv_file(fid, src, dst)

      src_entry = FileSystem.get_dir(src)
      dst_entry = FileSystem.get_dir(dst)

      refute MapSet.member?(src_entry.files, fid)
      assert MapSet.member?(dst_entry.files, fid)
    end

    test "returns {:error, :not_found} when file does not exist" do
      start_file_system!()
      {:ok, src} = FileSystem.mkdir(nil, "src")
      {:ok, dst} = FileSystem.mkdir(nil, "dst")

      assert {:error, :not_found} = FileSystem.mv_file("missing", src, dst)
    end

    test "returns {:error, :not_found} when source dir does not exist" do
      start_file_system!()
      {:ok, dir} = FileSystem.mkdir(nil, "dir")
      {:ok, fid} = FileSystem.put_file(dir, "f.txt")

      assert {:error, :not_found} = FileSystem.mv_file(fid, "missing", dir)
    end

    test "returns {:error, :not_found} when dest dir does not exist" do
      start_file_system!()
      {:ok, dir} = FileSystem.mkdir(nil, "dir")
      {:ok, fid} = FileSystem.put_file(dir, "f.txt")

      assert {:error, :not_found} = FileSystem.mv_file(fid, dir, "missing")
    end
  end

  # ── rm_file/2 ───────────────────────────────────────────────────────────

  describe "rm_file/2" do
    test "deletes a file and removes it from its parent" do
      start_file_system!()
      {:ok, dir} = FileSystem.mkdir(nil, "d")
      {:ok, fid} = FileSystem.put_file(dir, "f.txt")

      assert :ok = FileSystem.rm_file(fid, dir)

      assert FileSystem.stat(fid) == nil

      dir_entry = FileSystem.get_dir(dir)
      refute MapSet.member?(dir_entry.files, fid)
    end

    test "returns {:error, :not_found} for missing file" do
      start_file_system!()
      {:ok, dir} = FileSystem.mkdir(nil, "d")

      assert {:error, :not_found} = FileSystem.rm_file("missing", dir)
    end
  end

  # ── all_dirs/0 and all_files/0 ──────────────────────────────────────────

  describe "all_dirs/0 and all_files/0" do
    test "returns directory map containing created entries" do
      start_file_system!()
      {:ok, id} = FileSystem.mkdir(nil, "root")

      dirs = FileSystem.all_dirs()
      assert Map.has_key?(dirs, id)
      assert dirs[id].name == "root"
    end

    test "returns file map containing created entries" do
      start_file_system!()
      {:ok, dir} = FileSystem.mkdir(nil, "d")
      {:ok, fid} = FileSystem.put_file(dir, "f.txt", %{size: 1})

      files = FileSystem.all_files()
      assert Map.has_key?(files, fid)
      assert files[fid].name == "f.txt"
    end
  end
end
