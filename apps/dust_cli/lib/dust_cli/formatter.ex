defmodule Dust.CLI.Formatter do
  @moduledoc false

  def set_color(false), do: System.put_env("NO_COLOR", "1")
  def set_color(true), do: :ok

  # ── Status messages ────────────────────────────────────────────────────

  def success(msg), do: Owl.IO.puts([Owl.Data.tag("✓ ", :green), msg])
  def error(msg), do: Owl.IO.puts([Owl.Data.tag("✗ ", :red), msg], :stderr)
  def warning(msg), do: Owl.IO.puts([Owl.Data.tag("! ", :yellow), msg])
  def info(msg), do: Owl.IO.puts([Owl.Data.tag("→ ", :cyan), msg])
  def dim(msg), do: Owl.IO.puts(Owl.Data.tag(to_string(msg), :faint))

  # ── Headings ───────────────────────────────────────────────────────────

  def heading(title) do
    IO.puts("")
    Owl.Box.new(Owl.Data.tag(title, :bright),
      border_style: :solid_rounded,
      padding_x: 1,
      horizontal_align: :left
    )
    |> Owl.IO.puts()
  end

  # ── Key-value box ──────────────────────────────────────────────────────

  def kv_box(title, pairs) do
    max_key_len =
      pairs
      |> Enum.map(fn {k, _} -> String.length(to_string(k)) end)
      |> Enum.max(fn -> 0 end)

    content =
      pairs
      |> Enum.map(fn {k, v} ->
        padded = String.pad_trailing(to_string(k), max_key_len)
        [Owl.Data.tag(padded, :cyan), "  ", to_string(v)]
      end)
      |> Enum.intersperse(["\n"])
      |> List.flatten()

    Owl.Box.new(content,
      title: Owl.Data.tag(" #{title} ", :bright),
      border_style: :solid_rounded,
      padding_x: 1,
      horizontal_align: :left
    )
    |> Owl.IO.puts()
  end

  # ── Key-value display ──────────────────────────────────────────────────

  def kv(pairs) when is_list(pairs) do
    max_key_len =
      pairs
      |> Enum.map(fn {k, _} -> String.length(to_string(k)) end)
      |> Enum.max(fn -> 0 end)

    Enum.each(pairs, fn {key, value} ->
      padded = String.pad_trailing(to_string(key), max_key_len)
      Owl.IO.puts([Owl.Data.tag(padded, :cyan), "  ", to_string(value)])
    end)
  end

  # ── Info box ───────────────────────────────────────────────────────────

  def info_box(title, content) do
    Owl.Box.new(content,
      title: Owl.Data.tag(" #{title} ", :bright),
      border_style: :solid_rounded,
      padding_x: 1,
      horizontal_align: :left
    )
    |> Owl.IO.puts()
  end

  # ── Tables ─────────────────────────────────────────────────────────────

  def table(headers, rows) do
    str_headers = Enum.map(headers, &to_string/1)

    map_rows =
      Enum.map(rows, fn row ->
        str_headers
        |> Enum.zip(Enum.map(row, &to_string/1))
        |> Map.new()
      end)

    Owl.Table.new(map_rows,
      border_style: :solid_rounded,
      padding_x: 1,
      sort_columns: fn col_a, col_b ->
        (Enum.find_index(str_headers, &(&1 == col_a)) || 999) <=
          (Enum.find_index(str_headers, &(&1 == col_b)) || 999)
      end
    )
    |> Owl.IO.puts()
  end

  # ── Daemon connection error ────────────────────────────────────────────

  def daemon_unreachable do
    error("Cannot connect to the Dust daemon")
    IO.puts("")
    info_box("Tip", [
      "The daemon may not be running. Try:\n\n",
      Owl.Data.tag("  dustctl daemon start", :bright),
      "\n\nOr for first-time setup:\n\n",
      Owl.Data.tag("  dustctl init", :bright)
    ])
    IO.puts("")
  end
end
