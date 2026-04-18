defmodule Dust.CLI.Formatter do
  @moduledoc """
  Terminal output formatting with ANSI colors, tables, and status indicators.
  """

  # Color state is stored in the process dictionary for simplicity in an escript
  def set_color(enabled) do
    Process.put(:dust_cli_color, enabled)
  end

  defp color? do
    Process.get(:dust_cli_color, true)
  end

  # ── Status messages ────────────────────────────────────────────────────

  def success(msg), do: IO.puts(colorize("✓ #{msg}", :green))
  def error(msg), do: IO.puts(:stderr, colorize("✗ #{msg}", :red))
  def warning(msg), do: IO.puts(colorize("⚠ #{msg}", :yellow))
  def info(msg), do: IO.puts(colorize("→ #{msg}", :cyan))
  def dim(msg), do: IO.puts(colorize(msg, :dim))

  # ── Headings ───────────────────────────────────────────────────────────

  def heading(title) do
    IO.puts("")
    IO.puts(colorize("  #{title}", :bold))
    IO.puts(colorize("  #{String.duplicate("─", String.length(title) + 2)}", :dim))
  end

  # ── Key-value display ──────────────────────────────────────────────────

  def kv(pairs) when is_list(pairs) do
    max_key_len =
      pairs
      |> Enum.map(fn {k, _} -> String.length(to_string(k)) end)
      |> Enum.max(fn -> 0 end)

    Enum.each(pairs, fn {key, value} ->
      padded_key = String.pad_trailing(to_string(key), max_key_len)
      IO.puts("  #{colorize(padded_key, :cyan)}  #{value}")
    end)
  end

  # ── Tables ─────────────────────────────────────────────────────────────

  def table(headers, rows) do
    all_rows = [headers | rows]

    col_widths =
      Enum.map(0..(length(headers) - 1), fn col ->
        all_rows
        |> Enum.map(fn row -> row |> Enum.at(col, "") |> to_string() |> String.length() end)
        |> Enum.max()
      end)

    # Header
    header_line =
      headers
      |> Enum.zip(col_widths)
      |> Enum.map(fn {h, w} -> String.pad_trailing(to_string(h), w) end)
      |> Enum.join("  ")

    IO.puts("  #{colorize(header_line, :bold)}")

    # Separator
    separator =
      col_widths
      |> Enum.map(&String.duplicate("─", &1))
      |> Enum.join("──")

    IO.puts("  #{colorize(separator, :dim)}")

    # Rows
    Enum.each(rows, fn row ->
      line =
        row
        |> Enum.zip(col_widths)
        |> Enum.map(fn {cell, w} -> String.pad_trailing(to_string(cell), w) end)
        |> Enum.join("  ")

      IO.puts("  #{line}")
    end)
  end

  # ── Progress ───────────────────────────────────────────────────────────

  def spinner(msg) do
    IO.write(colorize("⟳ #{msg}...", :yellow))
  end

  def spinner_done do
    IO.write("\r")
    IO.write(String.duplicate(" ", 80))
    IO.write("\r")
  end

  # ── Daemon connection error ────────────────────────────────────────────

  def daemon_unreachable do
    error("Cannot connect to the Dust daemon")
    IO.puts("")
    IO.puts("  The daemon may not be running. Try:")
    IO.puts("")
    IO.puts("    #{colorize("dustctl daemon start", :bold)}")
    IO.puts("")
    IO.puts("  Or if this is your first time:")
    IO.puts("")
    IO.puts("    #{colorize("dustctl init", :bold)}")
    IO.puts("")
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp colorize(text, style) do
    if color?() do
      "#{ansi(style)}#{text}#{ansi(:reset)}"
    else
      text
    end
  end

  defp ansi(:red), do: "\e[31m"
  defp ansi(:green), do: "\e[32m"
  defp ansi(:yellow), do: "\e[33m"
  defp ansi(:blue), do: "\e[34m"
  defp ansi(:cyan), do: "\e[36m"
  defp ansi(:bold), do: "\e[1m"
  defp ansi(:dim), do: "\e[2m"
  defp ansi(:reset), do: "\e[0m"
end
