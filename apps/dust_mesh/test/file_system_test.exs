defmodule Dust.Mesh.FileSystemTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Dust.Mesh.FileSystem

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_file_system! do
    test_db_path = Dust.Utilities.File.mesh_db_dir()

    File.mkdir_p!(test_db_path)
    start_supervised!({Registry, keys: :duplicate, name: Dust.Mesh.Registry})
    start_supervised!({CubDB, data_dir: test_db_path, name: Dust.Mesh.Database})
    start_supervised!(Dust.Mesh.NodeRegistry)
    start_supervised!(Dust.Mesh.FileSystem.DirMap)
    start_supervised!(Dust.Mesh.FileSystem.FileMap)
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
    start_file_system!()

    on_exit(fn ->
      if old_env do
        Application.put_env(:dust_utilities, :config, old_env)
      else
        Application.delete_env(:dust_utilities, :config)
      end
    end)

    :ok
  end

  # ── mkdir/2 ──────────────────────────────────────────────────────────────

  describe "mkdir/2" do
    test "creates a root directory with nil parent" do
      assert {:ok, id} = FileSystem.mkdir(nil, "root")
      assert is_binary(id)

      entry = FileSystem.get_dir(id)
      assert entry.name == "root"
      assert entry.parent_id == nil
      assert %DateTime{} = entry.created_at
    end

    test "creates a child directory under a parent" do
      {:ok, parent_id} = FileSystem.mkdir(nil, "parent")
      {:ok, child_id} = FileSystem.mkdir(parent_id, "child")

      parent = FileSystem.get_dir(parent_id)
      assert parent.name == "parent"

      child = FileSystem.get_dir(child_id)
      assert child.name == "child"
      assert child.parent_id == parent_id
    end

    test "returns {:error, :parent_not_found} for non-existent parent" do
      assert {:error, :parent_not_found} = FileSystem.mkdir("nonexistent", "child")
    end

    test "raises FunctionClauseError for non-binary name" do
      assert_raise FunctionClauseError, fn ->
        FileSystem.mkdir(nil, 123)
      end
    end
  end

  # ── get_dir/1 ────────────────────────────────────────────────────────────

  describe "get_dir/1" do
    test "returns entry for existing directory" do
      {:ok, id} = FileSystem.mkdir(nil, "docs")

      entry = FileSystem.get_dir(id)
      assert entry.name == "docs"
    end

    test "returns nil for non-existent directory" do
      assert FileSystem.get_dir("nonexistent") == nil
    end
  end

  # ── ls/1 ─────────────────────────────────────────────────────────────────

  describe "ls/1" do
    test "lists child directories and files" do
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
      assert {:error, :not_found} = FileSystem.ls("missing")
    end

    test "returns empty lists for directory with no children" do
      {:ok, id} = FileSystem.mkdir(nil, "empty")

      assert %{dirs: [], files: []} = FileSystem.ls(id)
    end
  end

  # ── rename_dir/2 ─────────────────────────────────────────────────────────

  describe "rename_dir/2" do
    test "renames a directory in place" do
      {:ok, id} = FileSystem.mkdir(nil, "old_name")

      :ok = FileSystem.rename_dir(id, "new_name")

      assert FileSystem.get_dir(id).name == "new_name"
    end

    test "returns {:error, :not_found} for missing directory" do
      assert {:error, :not_found} = FileSystem.rename_dir("missing", "x")
    end
  end

  # ── rmdir/2 ──────────────────────────────────────────────────────────────

  describe "rmdir/2" do
    test "removes an empty directory" do
      {:ok, parent} = FileSystem.mkdir(nil, "parent")
      {:ok, child} = FileSystem.mkdir(parent, "child")

      assert :ok = FileSystem.rmdir(child, parent)
      assert FileSystem.get_dir(child) == nil

      parent_entry = FileSystem.get_dir(parent)
      assert parent_entry.name == "parent"
    end

    test "removes a root directory with nil parent" do
      {:ok, id} = FileSystem.mkdir(nil, "root")

      assert :ok = FileSystem.rmdir(id, nil)
      assert FileSystem.get_dir(id) == nil
    end

    test "returns {:error, :not_empty} if directory has child dirs" do
      {:ok, parent} = FileSystem.mkdir(nil, "parent")
      {:ok, _child} = FileSystem.mkdir(parent, "child")

      assert {:error, :not_empty} = FileSystem.rmdir(parent, nil)
    end

    test "returns {:error, :not_empty} if directory has files" do
      {:ok, dir} = FileSystem.mkdir(nil, "dir")
      {:ok, _file} = FileSystem.put_file(dir, "file.txt")

      assert {:error, :not_empty} = FileSystem.rmdir(dir, nil)
    end

    test "returns {:error, :not_found} for missing directory" do
      assert {:error, :not_found} = FileSystem.rmdir("missing", nil)
    end
  end

  # ── put_file/3 ───────────────────────────────────────────────────────────

  describe "put_file/3" do
    test "adds a file to a directory" do
      {:ok, dir} = FileSystem.mkdir(nil, "docs")

      assert {:ok, file_id} = FileSystem.put_file(dir, "notes.txt", %{size: 100})
      assert is_binary(file_id)

      file_meta = FileSystem.stat(file_id)
      assert file_meta.dir_id == dir
    end

    test "automatically sets :name and :created_at in metadata" do
      {:ok, dir} = FileSystem.mkdir(nil, "docs")
      {:ok, file_id} = FileSystem.put_file(dir, "readme.md", %{mime: "text/plain"})

      meta = FileSystem.stat(file_id)
      assert meta.name == "readme.md"
      assert meta.mime == "text/plain"
      assert %DateTime{} = meta.created_at
    end

    test "returns {:error, :dir_not_found} for non-existent directory" do
      assert {:error, :dir_not_found} = FileSystem.put_file("missing", "f.txt")
    end
  end

  # ── stat/1 ───────────────────────────────────────────────────────────────

  describe "stat/1" do
    test "returns metadata with :id for existing file" do
      {:ok, dir} = FileSystem.mkdir(nil, "d")
      {:ok, fid} = FileSystem.put_file(dir, "f.txt", %{size: 5})

      meta = FileSystem.stat(fid)
      assert meta.id == fid
      assert meta.name == "f.txt"
      assert meta.size == 5
    end

    test "returns nil for non-existent file" do
      assert FileSystem.stat("missing") == nil
    end
  end

  # ── update_file/2 ───────────────────────────────────────────────────────

  describe "update_file/2" do
    test "merges updates into existing metadata" do
      {:ok, dir} = FileSystem.mkdir(nil, "d")
      {:ok, fid} = FileSystem.put_file(dir, "f.txt", %{size: 10})

      assert :ok = FileSystem.update_file(fid, %{size: 20, mime: "text/plain"})

      meta = FileSystem.stat(fid)
      assert meta.size == 20
      assert meta.mime == "text/plain"
      assert meta.name == "f.txt"
    end

    test "returns {:error, :not_found} for missing file" do
      assert {:error, :not_found} = FileSystem.update_file("missing", %{size: 0})
    end
  end

  # ── mv_file/3 ───────────────────────────────────────────────────────────

  describe "mv_file/3" do
    test "moves a file between directories" do
      {:ok, root} = FileSystem.mkdir(nil, "root")
      {:ok, src} = FileSystem.mkdir(root, "src")
      {:ok, dst} = FileSystem.mkdir(root, "dst")
      {:ok, fid} = FileSystem.put_file(src, "f.txt")

      assert :ok = FileSystem.mv_file(fid, src, dst)

      file_meta = FileSystem.stat(fid)
      assert file_meta.dir_id == dst
    end

    test "returns {:error, :not_found} when file does not exist" do
      {:ok, root} = FileSystem.mkdir(nil, "root")
      {:ok, src} = FileSystem.mkdir(root, "src")
      {:ok, dst} = FileSystem.mkdir(root, "dst")

      assert {:error, :not_found} = FileSystem.mv_file("missing", src, dst)
    end
  end

  # ── rm_file/2 ───────────────────────────────────────────────────────────

  describe "rm_file/2" do
    test "deletes a file and removes it from its parent" do
      {:ok, dir} = FileSystem.mkdir(nil, "d")
      {:ok, fid} = FileSystem.put_file(dir, "f.txt")

      assert :ok = FileSystem.rm_file(fid, dir)

      assert FileSystem.stat(fid) == nil
    end

    test "returns {:error, :not_found} for missing file" do
      {:ok, dir} = FileSystem.mkdir(nil, "d")

      assert {:error, :not_found} = FileSystem.rm_file("missing", dir)
    end
  end

  # ── all_dirs/0 and all_files/0 ──────────────────────────────────────────

  describe "all_dirs/0 and all_files/0" do
    test "returns directory map containing created entries" do
      {:ok, id} = FileSystem.mkdir(nil, "root")

      dirs = FileSystem.all_dirs()
      assert Map.has_key?(dirs, id)
      assert dirs[id].name == "root"
    end

    test "returns file map containing created entries" do
      {:ok, dir} = FileSystem.mkdir(nil, "d")
      {:ok, fid} = FileSystem.put_file(dir, "f.txt", %{size: 1})

      files = FileSystem.all_files()
      assert Map.has_key?(files, fid)
      assert files[fid].name == "f.txt"
    end
  end
end
