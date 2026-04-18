defmodule Dust.CLI.Commands.Status do
  @moduledoc """
  Handles `dustctl status` — displays comprehensive node status.
  """

  alias Dust.CLI.{Client, Formatter}

  def run(config, _args) do
    case Client.get(config, "/api/v1/status") do
      {200, {:ok, body}} ->
        display_status(body)
        0

      {:error, {:failed_connect, _}} ->
        Formatter.daemon_unreachable()
        1

      {:error, reason} ->
        Formatter.error("Connection failed: #{inspect(reason)}")
        1

      other ->
        Formatter.error("Unexpected response: #{inspect(other)}")
        1
    end
  end

  defp display_status(status) do
    ready = if status["ready"], do: "✓ ready", else: "⏳ bootstrapping"
    key_store = format_key_store(status["key_store"])
    uptime = format_uptime(status["uptime_ms"])

    network = status["network"] || %{}
    net_status = if network["connected"], do: "🟢 connected", else: "🔴 disconnected"

    Formatter.heading("Node Status")
    IO.puts("")

    Formatter.kv([
      {"Node", status["node"]},
      {"Version", status["version"] || "0.1.0"},
      {"Status", ready},
      {"Key Store", key_store},
      {"Tailscale", net_status},
      {"Self IP", network["self_ip"] || "—"},
      {"Uptime", uptime},
      {"Peers", "#{status["peers"]} connected"}
    ])

    unless network["connected"] do
      IO.puts("")
      Formatter.warning("Tailscale not connected. Run 'dustctl auth' to authenticate.")
    end

    if status["peers"] > 0 do
      IO.puts("")
      Formatter.dim("  Connected peers:")

      status["peer_names"]
      |> Enum.each(fn name ->
        IO.puts("    • #{name}")
      end)
    end

    disk = status["disk"]

    if disk do
      IO.puts("")
      Formatter.dim("  Disk:")

      Formatter.kv([
        {"Quota", format_bytes(disk["quota_bytes"])},
        {"Available", format_bytes(disk["available_bytes"])},
        {"Total", format_bytes(disk["total_bytes"])}
      ])
    end
  end

  defp format_key_store("unlocked"), do: "🔓 unlocked"
  defp format_key_store("locked"), do: "🔒 locked"
  defp format_key_store(other), do: "⚠ #{other}"

  defp format_uptime(nil), do: "unknown"

  defp format_uptime(ms) when is_integer(ms) do
    seconds = div(ms, 1_000)
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    days = div(hours, 24)

    cond do
      days > 0 -> "#{days}d #{rem(hours, 24)}h #{rem(minutes, 60)}m"
      hours > 0 -> "#{hours}h #{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end

  defp format_uptime(_), do: "unknown"

  defp format_bytes(nil), do: "unknown"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000_000 -> "#{Float.round(bytes / 1_000_000_000_000, 1)} TB"
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "unknown"
end
