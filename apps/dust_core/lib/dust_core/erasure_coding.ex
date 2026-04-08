defmodule Dust.Core.ErasureCoding do
  @moduledoc """
  Shard-level Reed-Solomon erasure coding for network redundancy.

  Splits a binary (typically a 4 MB encrypted chunk) into K data shards
  plus M parity shards.  **Any K of the K+M shards** can reconstruct the
  original data, so the network tolerates losing up to M nodes.
  """

  @default_k Application.compile_env(:dust_core, :default_k, 4)
  @default_m Application.compile_env(:dust_core, :default_m, 2)

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Encode a binary into K data shards + M parity shards.

  Returns `{:ok, shards}` where `shards` is a list of K+M binaries,
  indices 0..K-1 are data shards and K..K+M-1 are parity shards.

  Defaults to K=#{@default_k}, M=#{@default_m}.
  """
  @spec encode(binary()) :: {:ok, [binary()]} | {:error, term()}
  def encode(data) when is_binary(data), do: encode(data, @default_k, @default_m)

  @spec encode(binary(), pos_integer(), pos_integer()) :: {:ok, [binary()]} | {:error, term()}
  def encode(data, k, m) when is_binary(data) and k >= 1 and m >= 1 do
    data_shards = split_data(data, k)

    case RsSimd.encode(k, m, data_shards) do
      {:ok, parity_shards} -> {:ok, data_shards ++ parity_shards}
      {:error, _} = err -> err
    end
  end

  @doc """
  Reconstruct the original binary from at least K available shards.

  `available_shards` is a list of `{index, shard_binary}` tuples where
  `index` is the 0-based shard position (0..K-1 for data, K..K+M-1 for
  parity).

  `original_size` is the byte size of the original data before encoding
  (needed to strip padding from the last data shard).

  Returns `{:ok, data}` or `{:error, reason}`.

  > #### Corruption detection {: .warning}
  > `RsSimd` does not verify shard integrity.  Callers must validate
  > shards with a checksum (e.g. BLAKE3/SHA-256 stored alongside the
  > shard) and omit any corrupted shards before calling this function.
  """
  @spec decode([{non_neg_integer(), binary()}], non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def decode(available_shards, original_size),
    do: decode(available_shards, original_size, @default_k, @default_m)

  @spec decode(
          [{non_neg_integer(), binary()}],
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, binary()} | {:error, atom()}
  def decode(available_shards, original_size, k, m)
      when is_list(available_shards) and is_integer(original_size) and
             original_size >= 0 and k >= 1 and m >= 1 do
    if length(available_shards) < k do
      {:error, :insufficient_shards}
    else
      reconstruct(available_shards, original_size, k, m)
    end
  end

  # ── Internals ───────────────────────────────────────────────────────────

  # Split `data` into exactly `k` equal-sized shards, zero-padding the last
  # shard if necessary.
  @doc false
  @spec split_data(binary(), pos_integer()) :: [binary()]
  def split_data(data, k) do
    size = byte_size(data)
    # RsSimd requires shard sizes to be a non-zero multiple of 2 (SIMD alignment)
    shard_size = ceil_div(size, k) |> round_up_to_even()
    padded = pad_to(data, shard_size * k)

    for i <- 0..(k - 1) do
      :binary.part(padded, i * shard_size, shard_size)
    end
  end

  # Reconstruct the original binary using RsSimd.correct/4, which returns
  # all K data shards (repaired and ordered) in a single NIF call.
  @spec reconstruct(
          [{non_neg_integer(), binary()}],
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, binary()} | {:error, atom()}
  defp reconstruct(available_shards, original_size, k, m) do
    {original_indexed, recovery_indexed} =
      Enum.split_with(available_shards, fn {idx, _} -> idx < k end)

    # RsSimd uses 0-based recovery indices (0..M-1), but our caller stores
    # parity shards at absolute positions K..K+M-1.  Rebase them.
    rebased_recovery =
      Enum.map(recovery_indexed, fn {idx, shard} -> {idx - k, shard} end)

    # RsSimd.correct/4 returns {:ok, [shard0, shard1, ..., shard_{k-1}]}
    # — the full ordered list of data shards, with missing ones restored.
    case RsSimd.correct(k, m, original_indexed, rebased_recovery) do
      {:ok, data_shards} ->
        reconstructed = IO.iodata_to_binary(data_shards)
        {:ok, :binary.part(reconstructed, 0, original_size)}

      {:error, _} ->
        {:error, :decode_failed}
    end
  end

  # ── Utilities ───────────────────────────────────────────────────────────

  @spec pad_to(binary(), non_neg_integer()) :: binary()
  defp pad_to(data, target_size) when byte_size(data) >= target_size, do: data

  defp pad_to(data, target_size) do
    data <> :binary.copy(<<0>>, target_size - byte_size(data))
  end

  @spec ceil_div(non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp ceil_div(a, b), do: div(a + b - 1, b)

  # Round up to the nearest even number (SIMD requires multiple-of-2 shard sizes)
  @spec round_up_to_even(pos_integer()) :: pos_integer()
  defp round_up_to_even(n) when rem(n, 2) == 0, do: n
  defp round_up_to_even(n), do: n + 1
end
