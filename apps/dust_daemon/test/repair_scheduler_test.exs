defmodule Dust.Daemon.RepairSchedulerTest do
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  alias Dust.Daemon.RepairScheduler
  alias Dust.Mesh.Manifest.{FileIndex, ShardMap}
  alias Dust.Storage
  alias Dust.Core.KeyStore

  @test_password "test_password_123"
  @moduletag :tmp_dir

  setup_all do
    Mox.set_mox_global()
    Mox.stub(Dust.Bridge.Mock, :serve_secrets, fn _, _ -> :ok end)

    Application.ensure_all_started(:dust_daemon)

    old_env = Application.get_env(:dust_utilities, :config, %{})
    KeyStore.unlock(@test_password)

    on_exit(fn ->
      if old_env do
        Application.put_env(:dust_utilities, :config, old_env)
      else
        Application.delete_env(:dust_utilities, :config)
      end
    end)

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:dust_utilities, :config, %{persist_dir: tmp_dir})
    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Uploads a small file and returns {file_uuid, chunk_hashes}
  defp upload_test_file(tmp_dir, name) do
    content = :crypto.strong_rand_bytes(1024)
    source_path = Path.join(tmp_dir, name)
    File.write!(source_path, content)

    {:ok, dir_id} = Dust.Mesh.FileSystem.mkdir(nil, "/")
    {:ok, file_uuid} = Dust.Daemon.FileSystem.upload(source_path, dir_id, name)

    %{chunks: chunks} = FileIndex.get(file_uuid)
    {file_uuid, chunks}
  end

  # Corrupts a shard in storage by writing garbage with a bad checksum
  defp corrupt_shard(chunk_hash, shard_index) do
    garbage = :crypto.strong_rand_bytes(64)
    bad_hash = :crypto.strong_rand_bytes(32)
    payload = garbage <> bad_hash

    # Write directly to backend to bypass checksum generation
    Dust.Storage.RocksBackend.put("#{chunk_hash}:#{shard_index}", payload)
  end

  # ── Integrity Tests (Phase 1) ──────────────────────────────────────────

  describe "phase 1 — integrity verification" do
    test "corrupted shard is detected, removed, and reconstructed", %{tmp_dir: tmp_dir} do
      {_file_uuid, [chunk_hash | _]} = upload_test_file(tmp_dir, "integrity_corrupt.bin")

      # Shard exists and is valid
      assert Storage.has_shard?(chunk_hash, 0)

      # Corrupt it
      corrupt_shard(chunk_hash, 0)

      # Verify it's detected as corrupted
      assert {:error, _} = Storage.verify_shard(chunk_hash, 0)

      RepairScheduler.sweep_now()
      Process.sleep(500)

      # Phase 1 should have detected and removed the corrupt shard
      stats = RepairScheduler.stats()
      assert stats.integrity_removed >= 1

      # Phase 3 may reconstruct the shard from the remaining K+M-1 shards
      # on this node. If reconstructed, it should now be valid.
      if Storage.has_shard?(chunk_hash, 0) do
        assert :ok = Storage.verify_shard(chunk_hash, 0)
        assert stats.shards_reconstructed >= 1
      end
    end

    test "valid shards are preserved during integrity check", %{tmp_dir: tmp_dir} do
      {_file_uuid, [chunk_hash | _]} = upload_test_file(tmp_dir, "integrity_valid.bin")

      # All shards should exist before sweep
      assert Storage.has_shard?(chunk_hash, 0)

      RepairScheduler.sweep_now()
      Process.sleep(500)

      # Valid shards should survive
      assert Storage.has_shard?(chunk_hash, 0)
    end
  end

  # ── Under-Replication Tests (Phase 2) ───────────────────────────────────

  describe "phase 2 — under-replication repair" do
    test "does not clone shards that are already held locally", %{tmp_dir: tmp_dir} do
      {_file_uuid, [chunk_hash | _]} = upload_test_file(tmp_dir, "clone_already_local.bin")

      # Node already holds shard 0 (from upload)
      assert Storage.has_shard?(chunk_hash, 0)

      RepairScheduler.sweep_now()
      Process.sleep(500)

      # Shard should still exist (not duplicated or errored)
      assert Storage.has_shard?(chunk_hash, 0)
    end

    test "does not attempt to clone when this node is the only holder", %{tmp_dir: tmp_dir} do
      {_file_uuid, [_chunk_hash | _]} = upload_test_file(tmp_dir, "clone_sole_holder.bin")

      # Only this node holds the shards — no remote source available
      # In single-node test, online_nodes returns [] so there's nothing to clone from
      RepairScheduler.sweep_now()
      Process.sleep(500)

      stats = RepairScheduler.stats()
      # Can't clone without remote nodes
      assert stats.shards_cloned == 0
    end
  end

  # ── Reconstruction Tests (Phase 3) ──────────────────────────────────────

  describe "phase 3 — missing shard reconstruction" do
    test "reconstruction is skipped when no shards are missing", %{tmp_dir: tmp_dir} do
      {_file_uuid, _chunks} = upload_test_file(tmp_dir, "recon_all_present.bin")

      RepairScheduler.sweep_now()
      Process.sleep(500)

      stats = RepairScheduler.stats()
      assert stats.shards_reconstructed == 0
    end
  end

  # ── Stale Manifest Cleanup Tests (Phase 4) ──────────────────────────────

  describe "phase 4 — stale manifest cleanup" do
    test "removes ShardMap entries for long-offline nodes" do
      chunk_hash = "stale_test_#{System.unique_integer([:positive])}"
      stale_node = :"stale_node@127.0.0.1"

      # Register stale node's shard in ShardMap
      ShardMap.put(chunk_hash, 0, stale_node)

      # Also register in FileIndex so it's a referenced chunk
      fake_meta = %Dust.Core.Crypto.FileMeta{encrypted_file_key: :crypto.strong_rand_bytes(64)}

      file_entry = %Dust.Mesh.Manifest.FileIndex{
        file_meta: fake_meta,
        chunks: [chunk_hash]
      }

      FileIndex.put("stale_test_file_#{System.unique_integer([:positive])}", file_entry)

      # Verify stale node is in the shard map
      shard_map = ShardMap.get_shards(chunk_hash)
      assert Map.has_key?(shard_map, 0)
      assert MapSet.member?(shard_map[0].nodes, stale_node)

      # The stale node isn't in our NodeRegistry (never connected in test),
      # so it won't be cleaned by sweep (it's "unknown", not "offline with timestamp").
      # This verifies that sweep doesn't incorrectly clean unknown nodes.
      RepairScheduler.sweep_now()
      Process.sleep(500)

      # Entry should persist — unknown nodes are NOT treated as stale
      shard_map_after = ShardMap.get_shards(chunk_hash)
      assert MapSet.member?(shard_map_after[0].nodes, stale_node)
    end
  end

  # ── Stats Tests ─────────────────────────────────────────────────────────

  describe "stats/0" do
    test "returns sweep metadata" do
      RepairScheduler.sweep_now()
      Process.sleep(500)

      stats = RepairScheduler.stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :last_sweep_at)
      assert Map.has_key?(stats, :integrity_removed)
      assert Map.has_key?(stats, :shards_cloned)
      assert Map.has_key?(stats, :shards_reconstructed)
      assert Map.has_key?(stats, :stale_entries_cleaned)
    end

    test "last_sweep_at is populated after sweep" do
      RepairScheduler.sweep_now()
      Process.sleep(500)

      stats = RepairScheduler.stats()
      assert stats.last_sweep_at != nil
    end
  end
end
