defmodule Dust.Core.ErasureCodingTest do
  use ExUnit.Case, async: true

  alias Dust.Core.ErasureCoding

  # Default: K=4 data shards, M=2 parity shards → 6 total, tolerate 2 losses

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp all_shards_with_indices(shards) do
    Enum.with_index(shards) |> Enum.map(fn {s, i} -> {i, s} end)
  end

  defp drop_shards(shards, indices_to_drop) do
    shards
    |> all_shards_with_indices()
    |> Enum.reject(fn {i, _} -> i in indices_to_drop end)
  end

  # ── encode/1 ──────────────────────────────────────────────────────────────

  describe "encode/1" do
    test "produces 6 shards by default (K=4, M=2)" do
      data = :crypto.strong_rand_bytes(1000)
      {:ok, shards} = ErasureCoding.encode(data)
      assert length(shards) == 6
    end

    test "all shards have equal size" do
      data = :crypto.strong_rand_bytes(1000)
      {:ok, shards} = ErasureCoding.encode(data)
      sizes = Enum.map(shards, &byte_size/1) |> Enum.uniq()
      assert length(sizes) == 1
    end

    test "shard size is ceil(data_size / K)" do
      data = :crypto.strong_rand_bytes(1000)
      {:ok, shards} = ErasureCoding.encode(data)
      expected_shard_size = ceil(1000 / 4)
      assert byte_size(hd(shards)) == expected_shard_size
    end

    test "handles data exactly divisible by K" do
      data = :crypto.strong_rand_bytes(400)
      {:ok, shards} = ErasureCoding.encode(data)
      assert byte_size(hd(shards)) == 100
    end
  end

  # ── encode/3 with custom K, M ────────────────────────────────────────────

  describe "encode/3" do
    test "K=3, M=3 produces 6 shards" do
      data = :crypto.strong_rand_bytes(600)
      {:ok, shards} = ErasureCoding.encode(data, 3, 3)
      assert length(shards) == 6
    end

    test "K=2, M=1 produces 3 shards" do
      data = :crypto.strong_rand_bytes(500)
      {:ok, shards} = ErasureCoding.encode(data, 2, 1)
      assert length(shards) == 3
    end
  end

  # ── Round-trip: encode → decode with all shards ──────────────────────────

  describe "round-trip with all shards" do
    test "small data" do
      data = :crypto.strong_rand_bytes(100)
      {:ok, shards} = ErasureCoding.encode(data)
      available = all_shards_with_indices(shards)
      assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data))
    end

    test "data not divisible by K" do
      data = :crypto.strong_rand_bytes(1001)
      {:ok, shards} = ErasureCoding.encode(data)
      available = all_shards_with_indices(shards)
      assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data))
    end

    test "exact block boundary (divisible by K)" do
      data = :crypto.strong_rand_bytes(2000)
      {:ok, shards} = ErasureCoding.encode(data)
      available = all_shards_with_indices(shards)
      assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data))
    end
  end

  # ── Shard loss tolerance ────────────────────────────────────────────────

  describe "shard loss tolerance (K=4, M=2)" do
    setup do
      data = :crypto.strong_rand_bytes(2000)
      {:ok, shards} = ErasureCoding.encode(data)
      %{data: data, shards: shards}
    end

    test "recovers after losing 1 data shard", %{data: data, shards: shards} do
      available = drop_shards(shards, [0])
      assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data))
    end

    test "recovers after losing 1 parity shard", %{data: data, shards: shards} do
      available = drop_shards(shards, [4])
      assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data))
    end

    test "recovers after losing 2 data shards", %{data: data, shards: shards} do
      available = drop_shards(shards, [1, 3])
      assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data))
    end

    test "recovers after losing 2 parity shards", %{data: data, shards: shards} do
      available = drop_shards(shards, [4, 5])
      assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data))
    end

    test "recovers after losing 1 data + 1 parity shard", %{data: data, shards: shards} do
      available = drop_shards(shards, [2, 5])
      assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data))
    end

    test "fails with insufficient shards (3 lost)", %{shards: shards} do
      available = drop_shards(shards, [0, 2, 4])
      assert {:error, :insufficient_shards} = ErasureCoding.decode(available, 2000)
    end
  end

  # ── Exhaustive combo test ──────────────────────────────────────────────

  describe "exhaustive 4-of-6 shard recovery" do
    test "all C(6,4)=15 combinations work" do
      data = :crypto.strong_rand_bytes(800)
      {:ok, shards} = ErasureCoding.encode(data)
      all_indexed = all_shards_with_indices(shards)

      # Generate all combinations of 4 shards from 6
      combos =
        for a <- 0..5,
            b <- (a + 1)..5//1,
            c <- (b + 1)..5//1,
            d <- (c + 1)..5//1,
            do: [a, b, c, d]

      assert length(combos) == 15

      for combo <- combos do
        available = Enum.filter(all_indexed, fn {i, _} -> i in combo end)

        assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data)),
               "Failed for shard combo #{inspect(combo)}"
      end
    end
  end

  # ── Custom K/M round-trip ──────────────────────────────────────────────

  describe "custom K/M round-trip" do
    test "K=3, M=3: tolerate 3 shard losses" do
      data = :crypto.strong_rand_bytes(900)
      {:ok, shards} = ErasureCoding.encode(data, 3, 3)

      # Drop shards 0, 2, 4
      available =
        shards
        |> Enum.with_index()
        |> Enum.reject(fn {_, i} -> i in [0, 2, 4] end)
        |> Enum.map(fn {s, i} -> {i, s} end)

      assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data), 3, 3)
    end

    test "K=2, M=1: tolerate 1 shard loss" do
      data = :crypto.strong_rand_bytes(500)
      {:ok, shards} = ErasureCoding.encode(data, 2, 1)

      available =
        shards
        |> Enum.with_index()
        |> Enum.reject(fn {_, i} -> i == 1 end)
        |> Enum.map(fn {s, i} -> {i, s} end)

      assert {:ok, ^data} = ErasureCoding.decode(available, byte_size(data), 2, 1)
    end
  end

  # ── split_data/2 ───────────────────────────────────────────────────────

  describe "split_data/2" do
    test "splits evenly divisible data" do
      data = <<1, 2, 3, 4, 5, 6, 7, 8>>
      shards = ErasureCoding.split_data(data, 4)
      assert length(shards) == 4
      assert shards == [<<1, 2>>, <<3, 4>>, <<5, 6>>, <<7, 8>>]
    end

    test "pads when data is not divisible by K" do
      data = <<1, 2, 3, 4, 5>>
      shards = ErasureCoding.split_data(data, 4)
      assert length(shards) == 4
      # ceil(5/4) = 2 bytes per shard, padded to 8 bytes total
      assert shards == [<<1, 2>>, <<3, 4>>, <<5, 0>>, <<0, 0>>]
    end
  end
end
