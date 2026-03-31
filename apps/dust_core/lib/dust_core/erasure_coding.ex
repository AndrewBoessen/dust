defmodule Dust.Core.ErasureCoding do
  @moduledoc """
  Shard-level Reed-Solomon erasure coding for network redundancy.

  Splits a binary (typically a 4 MB encrypted chunk) into K data shards
  plus M parity shards.  **Any K of the K+M shards** can reconstruct the
  original data, so the network tolerates losing up to M nodes.

  Internally uses byte-interleaved RS encoding via `ReedSolomonEx`:
  for each byte position across the K data shards, a K-symbol RS
  codeword is encoded with M parity symbols, producing M parity bytes
  that populate the parity shards.
  """

  # Default number of data shards
  @default_k 4
  # Default number of parity shards
  @default_m 2

  # Byte positions processed per parallel task during encode/decode.
  # Larger values reduce task overhead; smaller values improve parallelism.
  @batch_size 8192

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Encode a binary into K data shards + M parity shards.

  Returns `{:ok, shards}` where `shards` is a list of K+M binaries,
  indices 0..K-1 are data shards and K..K+M-1 are parity shards.

  Defaults to K=#{@default_k}, M=#{@default_m}.
  """
  @spec encode(binary()) :: {:ok, [binary()]}
  def encode(data) when is_binary(data), do: encode(data, @default_k, @default_m)

  @spec encode(binary(), pos_integer(), pos_integer()) :: {:ok, [binary()]}
  def encode(data, k, m) when is_binary(data) and k >= 1 and m >= 1 and k + m <= 253 do
    data_shards = split_data(data, k)
    shard_size = byte_size(hd(data_shards))
    parity_shards = build_parity_shards(data_shards, k, m, shard_size)
    {:ok, data_shards ++ parity_shards}
  end

  @doc """
  Reconstruct the original binary from at least K available shards.

  `available_shards` is a list of `{index, shard_binary}` tuples where
  `index` is the 0-based shard position (0..K-1 for data, K..K+M-1 for parity).

  `original_size` is the byte size of the original data before encoding
  (needed to strip padding from the last data shard).

  Returns `{:ok, data}` or `{:error, reason}`.
  """
  @spec decode([{non_neg_integer(), binary()}], non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def decode(available_shards, original_size),
    do: decode(available_shards, original_size, @default_k, @default_m)

  @spec decode([{non_neg_integer(), binary()}], non_neg_integer(), pos_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def decode(available_shards, original_size, k, m)
      when is_list(available_shards) and is_integer(original_size) and
             k >= 1 and m >= 1 do
    if length(available_shards) < k do
      {:error, :insufficient_shards}
    else
      reconstruct(available_shards, original_size, k, m)
    end
  end

  # ── Internals ───────────────────────────────────────────────────────────

  @doc false
  @spec split_data(binary(), pos_integer()) :: [binary()]
  def split_data(data, k) do
    size = byte_size(data)
    shard_size = ceil_div(size, k)
    padded = pad_to(data, shard_size * k)

    for i <- 0..(k - 1) do
      :binary.part(padded, i * shard_size, shard_size)
    end
  end

  @spec build_parity_shards([binary()], pos_integer(), pos_integer(), non_neg_integer()) ::
          [binary()]
  defp build_parity_shards(_data_shards, _k, m, 0), do: List.duplicate(<<>>, m)

  defp build_parity_shards(data_shards, k, m, shard_size) do
    # Pre-convert data shards to tuples for fast byte access
    shard_tuples =
      Enum.map(data_shards, fn shard ->
        :erlang.binary_to_list(shard) |> :erlang.list_to_tuple()
      end)

    # Process byte positions in parallel batches
    num_batches = ceil_div(shard_size, @batch_size)

    parity_rows =
      0..(num_batches - 1)
      |> Task.async_stream(
        fn batch_idx ->
          start_pos = batch_idx * @batch_size
          end_pos = min(start_pos + @batch_size, shard_size) - 1

          for pos <- start_pos..end_pos do
            data_vector =
              for s <- 0..(k - 1), into: <<>> do
                <<:erlang.element(pos + 1, Enum.at(shard_tuples, s))>>
              end

            {:ok, parity} = ReedSolomonEx.encode_ecc(data_vector, m)
            parity
          end
        end,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, batch} -> batch end)

    # Transpose parity rows into M parity shards
    for p <- 0..(m - 1) do
      for row <- parity_rows, into: <<>> do
        <<:binary.at(row, p)>>
      end
    end
  end

  @spec reconstruct(
          [{non_neg_integer(), binary()}],
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, binary()} | {:error, atom()}
  defp reconstruct(available_shards, original_size, k, m) do
    n = k + m
    shard_size = byte_size(elem(hd(available_shards), 1))

    # Build a map of index -> shard tuple for fast byte access
    shard_map =
      Map.new(available_shards, fn {idx, shard} ->
        {idx, :erlang.binary_to_list(shard) |> :erlang.list_to_tuple()}
      end)

    # Determine which positions are missing (erasures)
    present = Map.keys(shard_map) |> MapSet.new()
    erasure_positions = for i <- 0..(n - 1), i not in present, do: i

    if shard_size == 0 do
      {:ok, <<>>}
    else
      # Process byte positions in parallel batches
      num_batches = ceil_div(shard_size, @batch_size)

      result =
        0..(num_batches - 1)
        |> Task.async_stream(
          fn batch_idx ->
            start_pos = batch_idx * @batch_size
            end_pos = min(start_pos + @batch_size, shard_size) - 1

            for pos <- start_pos..end_pos do
              # Build the n-byte codeword: data bytes from present shards, 0 for missing
              codeword =
                for i <- 0..(n - 1), into: <<>> do
                  case Map.get(shard_map, i) do
                    nil -> <<0>>
                    tuple -> <<:erlang.element(pos + 1, tuple)>>
                  end
                end

              case ReedSolomonEx.correct(codeword, m, erasure_positions) do
                {:ok, corrected} ->
                  # Extract the first K bytes (original data symbols)
                  :binary.part(corrected, 0, k)

                {:error, _} ->
                  :decode_error
              end
            end
          end,
          ordered: true,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, batch} -> batch end)

      if Enum.any?(result, &(&1 == :decode_error)) do
        {:error, :decode_failed}
      else
        # result is a list of K-byte binaries, one per byte position:
        #   [<<D0[0], D1[0], D2[0], D3[0]>>, <<D0[1], D1[1], ...>>, ...]
        # We need to transpose back into sequential shard order:
        #   <<D0[0], D0[1], ..., D1[0], D1[1], ..., ...>>
        reconstructed =
          for shard_idx <- 0..(k - 1), into: <<>> do
            for row <- result, into: <<>> do
              <<:binary.at(row, shard_idx)>>
            end
          end

        {:ok, :binary.part(reconstructed, 0, original_size)}
      end
    end
  end

  # ── Utilities ───────────────────────────────────────────────────────────

  @spec pad_to(binary(), non_neg_integer()) :: binary()
  defp pad_to(data, target_size) when byte_size(data) >= target_size, do: data

  defp pad_to(data, target_size) do
    pad_len = target_size - byte_size(data)
    data <> :binary.copy(<<0>>, pad_len)
  end

  @spec ceil_div(non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp ceil_div(a, b), do: div(a + b - 1, b)
end
