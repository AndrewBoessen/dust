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

  # ── API error handler ──────────────────────────────────────────────────

  @doc """
  Prints a human-readable error for any API response or connection failure.
  Returns 1 so callers can do `other -> Formatter.api_error(other)`.
  """
  def api_error(response) do
    case response do
      {:error, {:failed_connect, _}} ->
        daemon_unreachable()

      {:error, {:timeout, _}} ->
        error("Request timed out — the daemon may be busy or unreachable")

      {:error, :timeout} ->
        error("Request timed out — the daemon may be busy or unreachable")

      {:error, {:tls_alert, _}} ->
        error("TLS error — check your connection settings")

      {:error, {:inet, _mods, :econnrefused}} ->
        daemon_unreachable()

      {:error, reason} ->
        error("Connection error: #{format_httpc_reason(reason)}")

      {401, {:ok, %{"error" => "invalid_password"}}} ->
        error("Invalid password")

      {401, {:ok, %{"error" => "unauthorized"}}} ->
        error("API authentication failed — check your api_token file in the data directory")

      {401, _} ->
        error("Unauthorized — check your API token")

      {403, {:ok, %{"error" => reason}}} ->
        error("Permission denied: #{reason}")

      {403, _} ->
        error("Permission denied")

      {422, {:ok, %{"error" => reason}}} ->
        error("Invalid request: #{reason}")

      {422, _} ->
        error("Invalid request — the daemon rejected the input")

      {500, {:ok, %{"error" => reason}}} ->
        error("Daemon internal error: #{reason}")
        info("Check the daemon logs for more details.")

      {500, _} ->
        error("Daemon encountered an internal error")
        info("Check the daemon logs for more details.")

      {503, {:ok, %{"error" => reason}}} ->
        error("Service unavailable: #{reason}")

      {503, _} ->
        error("Service unavailable — storage may be temporarily unavailable, try again shortly")

      {status, {:ok, %{"error" => reason}}} ->
        error("Error (HTTP #{status}): #{reason}")

      {status, {:error, _}} ->
        error("Received an unreadable response from the daemon (HTTP #{status})")
        info("The daemon may be running an incompatible version — try 'dustctl daemon stop && dustctl daemon start'")

      {status, _} ->
        error("Unexpected response from the daemon (HTTP #{status})")
        info("Try restarting the daemon with 'dustctl daemon stop && dustctl daemon start'")
    end

    1
  end

  defp format_httpc_reason({:econnrefused, _}), do: "connection refused"
  defp format_httpc_reason(:econnrefused), do: "connection refused"
  defp format_httpc_reason({:econnreset, _}), do: "connection reset by peer"
  defp format_httpc_reason(:econnreset), do: "connection reset by peer"
  defp format_httpc_reason({:nxdomain, _}), do: "host not found"
  defp format_httpc_reason(:nxdomain), do: "host not found"
  defp format_httpc_reason({:ehostunreach, _}), do: "host unreachable"
  defp format_httpc_reason(:ehostunreach), do: "host unreachable"
  defp format_httpc_reason(:closed), do: "connection closed unexpectedly"
  defp format_httpc_reason(reason), do: inspect(reason)
end
