defmodule Dust.CLI.Commands.Config do
  @moduledoc """
  Handles configuration commands:

      dustctl config              Show current config
      dustctl config set KEY VAL  Update a runtime setting
  """

  alias Dust.CLI.{Client, Formatter}

  def run(config, ["set" | rest]) do
    set(config, rest)
  end

  def run(config, _args) do
    show(config)
  end

  # ── show ───────────────────────────────────────────────────────────────

  defp show(config) do
    case Client.get(config, "/api/v1/config") do
      {200, {:ok, %{"config" => cfg}}} ->
        rows =
          cfg
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map(fn {k, v} -> [to_string(k), format_value(k, v)] end)

        IO.puts("")
        Formatter.table(["Key", "Value"], rows)
        IO.puts("")
        Formatter.dim("Update with: dustctl config set <key> <value>")
        0

      other ->
        Formatter.api_error(other)
    end
  end

  # ── set ────────────────────────────────────────────────────────────────

  defp set(config, args) do
    case args do
      [key, value | _] ->
        parsed_value = parse_value(value)

        case Client.put(config, "/api/v1/config", %{key => parsed_value}) do
          {200, _} ->
            Formatter.success("#{key} = #{value}")
            0

          {207, {:ok, %{"results" => results}}} ->
            case results[key] do
              "ok" ->
                Formatter.success("#{key} = #{value}")
                0

              %{"error" => reason} ->
                Formatter.error("Failed to set #{key}: #{reason}")
                1
            end

          {_, {:ok, %{"error" => reason}}} ->
            Formatter.error("Failed: #{reason}")
            1

          other ->
            Formatter.api_error(other)
        end

      [_key] ->
        Formatter.error("Missing value")
        IO.puts("  Usage: dustctl config set <key> <value>")
        1

      [] ->
        Formatter.error("Missing key and value")
        IO.puts("  Usage: dustctl config set <key> <value>")
        1
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  @time_keys ["stale_node_timeout_ms"]

  defp format_value(k, v) when k in @time_keys and is_integer(v) do
    hours = Float.round(v / 3_600_000, 1)
    "#{v} ms (#{hours} h)"
  end

  defp format_value(_k, v) when is_integer(v) and v >= 1_000_000_000 do
    "#{v} (#{Float.round(v / 1_000_000_000, 1)} GB)"
  end

  defp format_value(_k, v) when is_integer(v) and v >= 1_000_000 do
    "#{v} (#{Float.round(v / 1_000_000, 1)} MB)"
  end

  defp format_value(_k, v), do: to_string(v)

  defp parse_value(str) do
    cond do
      str =~ ~r/^\d+$/ -> String.to_integer(str)
      str in ["true", "false"] -> str == "true"
      true -> str
    end
  end
end
