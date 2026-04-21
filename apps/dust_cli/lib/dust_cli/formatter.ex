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
    Owl.IO.puts(Owl.Data.tag(title, :bright))
    Owl.IO.puts(Owl.Data.tag(String.duplicate("─", String.length(title)), :faint))
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
      border_style: :none,
      padding_x: 1,
      sort_columns: fn cols ->
        Enum.sort_by(cols, fn col ->
          Enum.find_index(str_headers, &(&1 == col)) || 999
        end)
      end
    )
    |> Owl.IO.puts()
  end

  # ── Daemon connection error ────────────────────────────────────────────

  def daemon_unreachable do
    error("Cannot connect to the Dust daemon")
    IO.puts("")
    IO.puts("  The daemon may not be running. Try:")
    IO.puts("")
    Owl.IO.puts(["    ", Owl.Data.tag("dustctl daemon start", :bright)])
    IO.puts("")
    IO.puts("  Or if this is your first time:")
    IO.puts("")
    Owl.IO.puts(["    ", Owl.Data.tag("dustctl init", :bright)])
    IO.puts("")
  end
end
