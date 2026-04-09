defmodule Dust.StorageTest do
  use ExUnit.Case, async: false

  alias Dust.Storage

  @moduletag :tmp_dir

  # Stop the dust_storage application so its supervisor doesn't hold a
  # running RocksBackend under the registered name.  This lets each test
  # use start_supervised!/1 with a fresh temp directory.
  setup_all do
    Application.stop(:dust_storage)

    old_env = Application.get_env(:dust_utilities, :config, %{})

    on_exit(fn ->
      if old_env do
        Application.put_env(:dust_utilities, :config, old_env)
      else
        Application.delete_env(:dust_utilities, :config)
      end

      Application.ensure_all_started(:dust_storage)
    end)

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:dust_utilities, :config, %{persist_dir: tmp_dir})

    start_supervised!(Dust.Storage.RocksBackend)

    :ok
  end

  # ── put / get round-trip ───────────────────────────────────────────────

  describe "put_shard/3 and get_shard/2" do
    test "stores and retrieves a shard" do
      data = :crypto.strong_rand_bytes(128)
      assert :ok = Storage.put_shard("abc123", 0, data)
      assert {:ok, ^data} = Storage.get_shard("abc123", 0)
    end

    test "stores and retrieves a 1 MB shard" do
      data = :crypto.strong_rand_bytes(1_048_576)
      assert :ok = Storage.put_shard("big", 0, data)
      assert {:ok, ^data} = Storage.get_shard("big", 0)
    end

    test "stores an empty binary" do
      assert :ok = Storage.put_shard("empty", 0, <<>>)
      assert {:ok, <<>>} = Storage.get_shard("empty", 0)
    end

    test "overwrites an existing shard" do
      assert :ok = Storage.put_shard("overwrite", 0, <<1, 2, 3>>)
      assert :ok = Storage.put_shard("overwrite", 0, <<4, 5, 6>>)
      assert {:ok, <<4, 5, 6>>} = Storage.get_shard("overwrite", 0)
    end

    test "different shard indices are independent" do
      assert :ok = Storage.put_shard("multi", 0, <<1>>)
      assert :ok = Storage.put_shard("multi", 1, <<2>>)
      assert :ok = Storage.put_shard("multi", 2, <<3>>)

      assert {:ok, <<1>>} = Storage.get_shard("multi", 0)
      assert {:ok, <<2>>} = Storage.get_shard("multi", 1)
      assert {:ok, <<3>>} = Storage.get_shard("multi", 2)
    end
  end

  # ── get_shard not found ────────────────────────────────────────────────

  describe "get_shard/2 not found" do
    test "returns error for nonexistent key" do
      assert {:error, :not_found} = Storage.get_shard("nonexistent", 0)
    end

    test "returns error for wrong shard index" do
      :ok = Storage.put_shard("partial", 0, <<42>>)
      assert {:error, :not_found} = Storage.get_shard("partial", 1)
    end
  end

  # ── delete_shard ───────────────────────────────────────────────────────

  describe "delete_shard/2" do
    test "deletes an existing shard" do
      :ok = Storage.put_shard("del", 0, <<1, 2, 3>>)
      assert :ok = Storage.delete_shard("del", 0)
      assert {:error, :not_found} = Storage.get_shard("del", 0)
    end

    test "deleting a nonexistent shard is a no-op" do
      assert :ok = Storage.delete_shard("nope", 99)
    end
  end

  # ── delete_chunk_shards ────────────────────────────────────────────────

  describe "delete_chunk_shards/2" do
    test "removes all shards for a chunk" do
      for i <- 0..5 do
        :ok = Storage.put_shard("chunk-gc", i, :crypto.strong_rand_bytes(64))
      end

      assert :ok = Storage.delete_chunk_shards("chunk-gc", 6)

      for i <- 0..5 do
        assert {:error, :not_found} = Storage.get_shard("chunk-gc", i)
      end
    end

    test "zero total_shards is a no-op" do
      assert :ok = Storage.delete_chunk_shards("whatever", 0)
    end
  end

  # ── has_shard? ─────────────────────────────────────────────────────────

  describe "has_shard?/2" do
    test "returns true for an existing shard" do
      :ok = Storage.put_shard("exists", 0, <<99>>)
      assert Storage.has_shard?("exists", 0)
    end

    test "returns false for a nonexistent shard" do
      refute Storage.has_shard?("missing", 0)
    end

    test "returns false after deletion" do
      :ok = Storage.put_shard("gone", 0, <<1>>)
      :ok = Storage.delete_shard("gone", 0)
      refute Storage.has_shard?("gone", 0)
    end
  end
end
