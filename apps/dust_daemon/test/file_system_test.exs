defmodule Dust.Daemon.FileSystemTest do
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  alias Dust.Daemon.FileSystem
  alias Dust.Storage
  alias Dust.Mesh.Manifest
  alias Dust.Core.KeyStore
  alias Dust.Core.Fitness

  @test_password "test_password_123"

  @moduletag :tmp_dir

  setup_all do
    # Allow mock to be used by any process (safe since async: false)
    Mox.set_mox_global()
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

    test "progress notifications are broadcast during upload", %{tmp_dir: tmp_dir} do
      {:ok, _} = FileSystem.subscribe_upload_progress()

      content = :crypto.strong_rand_bytes(1024)
      source_path = Path.join(tmp_dir, "upload_progress.bin")
      File.write!(source_path, content)

      {:ok, dest_dir_id} = Dust.Mesh.FileSystem.mkdir(nil, "/")
      assert {:ok, file_uuid} = FileSystem.upload(source_path, dest_dir_id, "progress.bin")

      # Single chunk file → should receive exactly one progress message
      assert_receive {:upload_progress, ^file_uuid, 1, 1}
    end
  end

  describe "download/2" do
    test "round-trip: upload then download produces identical content", %{tmp_dir: tmp_dir} do
      # Create source file
      original_content = :crypto.strong_rand_bytes(2048)
      source_path = Path.join(tmp_dir, "source.bin")
      File.write!(source_path, original_content)

      {:ok, dest_dir_id} = Dust.Mesh.FileSystem.mkdir(nil, "/")

      # Upload
      assert {:ok, file_uuid} = FileSystem.upload(source_path, dest_dir_id, "source.bin")

      # Download to a different path
      download_path = Path.join(tmp_dir, "downloaded.bin")
      assert {:ok, ^download_path} = FileSystem.download(file_uuid, download_path)

      # Verify content matches
      assert File.read!(download_path) == original_content
    end

    test "multi-chunk round-trip with file larger than 4 MB", %{tmp_dir: tmp_dir} do
      # 4 MB chunk size + extra to force at least 2 chunks
      size = 4 * 1024 * 1024 + 1024
      original_content = :crypto.strong_rand_bytes(size)
      source_path = Path.join(tmp_dir, "large_source.bin")
      File.write!(source_path, original_content)

      {:ok, dest_dir_id} = Dust.Mesh.FileSystem.mkdir(nil, "/")

      # Upload
      assert {:ok, file_uuid} = FileSystem.upload(source_path, dest_dir_id, "large.bin")

      # Verify multiple chunks were created
      file_entry = Manifest.FileIndex.get(file_uuid)
      assert length(file_entry.chunks) >= 2

      # Download
      download_path = Path.join(tmp_dir, "large_downloaded.bin")
      assert {:ok, ^download_path} = FileSystem.download(file_uuid, download_path)

      # Verify content matches byte-for-byte
      assert File.read!(download_path) == original_content
    end

    test "returns error for non-existent file UUID", %{tmp_dir: tmp_dir} do
      download_path = Path.join(tmp_dir, "ghost.bin")

      assert {:error, :file_not_found} =
               FileSystem.download("nonexistent-uuid", download_path)
    end

    test "fitness model is updated after download", %{tmp_dir: tmp_dir} do
      # Upload a file
      content = :crypto.strong_rand_bytes(1024)
      source_path = Path.join(tmp_dir, "fitness_test.bin")
      File.write!(source_path, content)

      {:ok, dest_dir_id} = Dust.Mesh.FileSystem.mkdir(nil, "/")
      assert {:ok, file_uuid} = FileSystem.upload(source_path, dest_dir_id, "fitness.bin")

      # Download it — this should trigger fitness observations for node()
      download_path = Path.join(tmp_dir, "fitness_downloaded.bin")
      assert {:ok, _} = FileSystem.download(file_uuid, download_path)

      # The local node's model should no longer be the default
      # (success_rate should have moved toward 1.0 from the default 0.5)
      model = Fitness.ModelStore.get(node())
      default = Fitness.NodeEMA.new()

      assert model.success_rate > default.success_rate,
             "success_rate should increase after successful shard fetches"
    end

    test "progress notifications are broadcast during download", %{tmp_dir: tmp_dir} do
      # Subscribe to progress
      {:ok, _} = FileSystem.subscribe_download_progress()

      # Upload a file
      content = :crypto.strong_rand_bytes(1024)
      source_path = Path.join(tmp_dir, "progress_test.bin")
      File.write!(source_path, content)

      {:ok, dest_dir_id} = Dust.Mesh.FileSystem.mkdir(nil, "/")
      assert {:ok, file_uuid} = FileSystem.upload(source_path, dest_dir_id, "progress.bin")

      # Download
      download_path = Path.join(tmp_dir, "progress_downloaded.bin")
      assert {:ok, _} = FileSystem.download(file_uuid, download_path)

      # Should have received at least one progress message
      assert_receive {:download_progress, ^file_uuid, 1, 1}
    end
  end
end
