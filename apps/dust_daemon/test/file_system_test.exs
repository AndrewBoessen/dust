defmodule Dust.Daemon.FileSystemTest do
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  alias Dust.Daemon.FileSystem
  alias Dust.Storage
  alias Dust.Mesh.Manifest
  alias Dust.Core.KeyStore

  @test_password "test_password_123"

  @moduletag :tmp_dir

  setup_all do
    Mox.stub(Dust.Bridge.Mock, :serve_secrets, fn _, _ -> :ok end)

    # Ensure network layer dependencies are up
    Application.ensure_all_started(:dust_daemon)

    old_env = Application.get_env(:dust_utilities, :persist_dir)

    # Unlock KeyStore
    KeyStore.unlock(@test_password)

    on_exit(fn ->
      if old_env do
        Application.put_env(:dust_utilities, :persist_dir, old_env)
      else
        Application.delete_env(:dust_utilities, :persist_dir)
      end
    end)

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    # Override persistent directory dynamically for this test process
    Application.put_env(:dust_utilities, :persist_dir, tmp_dir)
    :ok
  end

  describe "upload/3" do
    test "successfully uploads a real file, producing a valid UUID and storing shards", %{
      tmp_dir: tmp_dir
    } do
      # 1. Create a dummy file to upload
      local_path = Path.join(tmp_dir, "test_upload.txt")
      content = :crypto.strong_rand_bytes(1024)
      File.write!(local_path, content)

      {:ok, dest_dir_id} = Dust.Mesh.FileSystem.mkdir(nil, "/")

      # 2. Perform the actual upload
      assert {:ok, file_uuid} = FileSystem.upload(local_path, dest_dir_id, "test_upload.txt")

      # 3. Verify it was indexed in Mesh FileSystem
      assert is_binary(file_uuid)
      assert Dust.Mesh.FileSystem.all_files()[file_uuid] != nil

      # 4. Verify it was indexed in Manifest (FileIndex)
      file_entry = Manifest.FileIndex.get(file_uuid)
      assert file_entry != nil
      assert length(file_entry.chunks) > 0

      # 5. Verify the shards are placed on disk by Storage
      chunk_hash = hd(file_entry.chunks)
      assert {:ok, _shard_data} = Storage.get_shard(chunk_hash, 0)

      # 6. Verify Manifest tracked the ShardMap
      locations = Manifest.get_shard_locations(chunk_hash)
      assert map_size(locations) > 0
    end

    test "fails early and correctly bubbles up local file errors", %{tmp_dir: tmp_dir} do
      missing_path = Path.join(tmp_dir, "does_not_exist.bin")

      # Ensure it correctly returns the bad file error straight from the process
      assert {:error, :enoent} = FileSystem.upload(missing_path, "some-dir-id", "ghost.bin")
    end
  end
end
