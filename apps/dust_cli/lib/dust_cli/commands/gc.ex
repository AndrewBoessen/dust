defmodule Dust.CLI.Commands.Gc do
  @moduledoc """
  Handles garbage collection commands:

      dustctl gc stats    Show GC statistics from last sweep
      dustctl gc sweep    Trigger an immediate GC sweep
  """

  alias Dust.CLI.{Client, Formatter}

  def run(config, ["stats" | _]), do: stats(config)
  def run(config, ["sweep" | _]), do: sweep(config)

  def run(_config, args) do
    Formatter.error("Unknown gc command: #{Enum.join(args, " ")}")
    IO.puts("  Usage: dustctl gc <stats|sweep>")
    1
  end

  # ── stats ──────────────────────────────────────────────────────────────

  defp stats(config) do
    case Client.get(config, "/api/v1/gc/stats") do
      {200, {:ok, body}} ->
        last_sweep =
          case body["last_sweep_at"] do
            nil -> "never"
            ts -> ts
          end

        IO.puts("")
        Formatter.kv_box("GC Statistics", [
          {"Last sweep", last_sweep},
          {"Orphans removed", body["orphans_removed"] || 0},
          {"Replicas removed", body["replicas_removed"] || 0}
        ])
        IO.puts("")
        0

      other ->
        Formatter.api_error(other)
    end
  end

  # ── sweep ──────────────────────────────────────────────────────────────

  defp sweep(config) do
    Formatter.info("Triggering garbage collection sweep...")

    case Client.post(config, "/api/v1/gc/sweep") do
      {202, _} ->
        Formatter.success("GC sweep triggered")
        Formatter.dim("Run 'dustctl gc stats' to see results after completion.")
        0

      other ->
        Formatter.api_error(other)
    end
  end
end
