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
        Formatter.heading("Configuration")
        IO.puts("")

        pairs =
          cfg
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map(fn {k, v} -> {k, format_value(v)} end)

        Formatter.kv(pairs)
        IO.puts("")
        Formatter.dim("  Update with: dustctl config set <key> <value>")
        0

      {:error, {:failed_connect, _}} ->
        Formatter.daemon_unreachable()
        1

      other ->
        Formatter.error("Unexpected response: #{inspect(other)}")
        1
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

          {:error, {:failed_connect, _}} ->
            Formatter.daemon_unreachable()
            1

          other ->
            Formatter.error("Unexpected response: #{inspect(other)}")
            1
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

  defp format_value(v) when is_integer(v) and v >= 1_000_000_000 do
    "#{v} (#{Float.round(v / 1_000_000_000, 1)} GB)"
  end

  defp format_value(v) when is_integer(v) and v >= 1_000_000 do
    "#{v} (#{Float.round(v / 1_000_000, 1)} MB)"
  end

  defp format_value(v), do: to_string(v)

  defp parse_value(str) do
    cond do
      str =~ ~r/^\d+$/ -> String.to_integer(str)
      str in ["true", "false"] -> str == "true"
      true -> str
    end
  end
end
