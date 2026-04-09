defmodule Dust.Daemon.DiskManagerTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Dust.Daemon.DiskManager

  # We reset the quota after texts to keep state clean since DiskManager is registered globally.
  setup %{tmp_dir: tmp_dir} do
    old_env = Application.get_env(:dust_utilities, :config, %{})
    Application.put_env(:dust_utilities, :config, %{persist_dir: tmp_dir})
    current_quota = DiskManager.get_quota()

    on_exit(fn ->
      if old_env do
        Application.put_env(:dust_utilities, :config, old_env)
      else
        Application.delete_env(:dust_utilities, :config)
      end

      # Restore roughly enough quota to let everything be normal or a safe value 
      # but we have to swallow errors in case we can't afford the 'current_quota'
      DiskManager.set_quota(max(current_quota, 1))
    end)

    :ok
  end

  test "returns the current quota" do
    quota = DiskManager.get_quota()
    assert is_integer(quota)
    assert quota > 0
  end

  test "set_quota updates the quota and persists it" do
    # 1 GB should be available on any dev machine
    safe_test_quota = 1_000_000_000

    assert :ok == DiskManager.set_quota(safe_test_quota)
    assert DiskManager.get_quota() == safe_test_quota

    # Check persistence
    config_path = Dust.Utilities.Config.config_path()
    assert {:ok, body} = File.read(config_path)
    assert body =~ Integer.to_string(safe_test_quota)
  end

  test "set_quota rejects allocations larger than available OS physical capacity" do
    stats = DiskSpace.stat!(Dust.Utilities.File.persist_dir())

    # Request space strictly higher than what's physically available
    impossible_request = stats.available + 50_000_000_000

    assert {:error, :insufficient_disk_space} == DiskManager.set_quota(impossible_request)
  end

  test "can_allocate? correctly evaluates requested capacity against quota" do
    DiskManager.set_quota(10_000_000)

    # 5 shards, 1MB each = 5MB
    shard = :crypto.strong_rand_bytes(1_000_000)
    shards = Enum.map(1..5, fn _ -> shard end)

    # Should fit in the 10MB quota (assuming storage_db is basically empty here)
    assert DiskManager.can_allocate?(shards) == true

    # Adding 6 more MB (total 11MB) shouldn't be allowed
    too_many_shards = Enum.map(1..11, fn _ -> shard end)
    assert DiskManager.can_allocate?(too_many_shards) == false
  end
end
