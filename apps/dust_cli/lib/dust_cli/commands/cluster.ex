defmodule Dust.CLI.Commands.Cluster do
  @moduledoc """
  Handles cluster management:

      dustctl nodes
      dustctl invite
      dustctl join IP TOKEN
  """

  alias Dust.CLI.{Client, Formatter}

  # ── nodes ──────────────────────────────────────────────────────────────

  def nodes(config, _args) do
    case Client.get(config, "/api/v1/nodes") do
      {200, {:ok, %{"nodes" => nodes}}} ->
        display_nodes(nodes)
        0

      {:error, {:failed_connect, _}} ->
        Formatter.daemon_unreachable()
        1

      other ->
        Formatter.error("Unexpected response: #{inspect(other)}")
        1
    end
  end

  defp display_nodes(nodes) do
    Formatter.heading("Cluster Nodes")
    IO.puts("")

    headers = ["Node", "Status", "Fitness", "Role"]

    rows =
      Enum.map(nodes, fn node ->
        status = if node["online"], do: "🟢 online", else: "🔴 offline"
        role = if node["self"], do: "← this node", else: ""
        fitness = format_fitness(node["fitness"])
        [node["name"], status, fitness, role]
      end)

    Formatter.table(headers, rows)
    IO.puts("")
    Formatter.dim("  #{length(nodes)} total node(s)")
  end

  defp format_fitness(nil), do: "—"
  defp format_fitness(score) when is_number(score), do: "#{Float.round(score / 1, 2)}"
  defp format_fitness(_), do: "—"

  # ── invite ─────────────────────────────────────────────────────────────

  def invite(config, _args) do
    Formatter.info("Creating invite token...")

    case Client.post(config, "/api/v1/invite") do
      {201, {:ok, body}} ->
        IO.puts("")
        Formatter.success("Invite token created")
        IO.puts("")
        IO.puts("  To join this network from another machine, run:")
        IO.puts("")
        IO.puts("    \e[1mdustctl join #{body["join_ip"]} #{body["token"]}\e[0m")
        IO.puts("")
        Formatter.warning("This token can only be used once and expires in 10 minutes.")
        0

      {_, {:ok, %{"error" => reason}}} ->
        Formatter.error("Failed to create invite: #{reason}")
        1

      {:error, {:failed_connect, _}} ->
        Formatter.daemon_unreachable()
        1

      other ->
        Formatter.error("Unexpected response: #{inspect(other)}")
        1
    end
  end

  # ── join ───────────────────────────────────────────────────────────────

  def join(config, args) do
    case args do
      [peer_ip, token | _] ->
        Formatter.info("Joining network at #{peer_ip}...")

        case Client.post(config, "/api/v1/join", %{
               peer_address: peer_ip,
               token: token
             }) do
          {200, {:ok, %{"status" => "joined"}}} ->
            Formatter.success("Successfully joined the network via #{peer_ip}")
            IO.puts("")
            Formatter.info("Run 'dustctl nodes' to see cluster peers.")
            Formatter.info("Run 'dustctl unlock' to unlock the key store with the network password.")
            0

          {_, {:ok, %{"error" => reason}}} ->
            Formatter.error("Join failed: #{reason}")
            1

          {:error, {:failed_connect, _}} ->
            Formatter.daemon_unreachable()
            1

          other ->
            Formatter.error("Unexpected response: #{inspect(other)}")
            1
        end

      [_peer_ip] ->
        Formatter.error("Missing invite token")
        IO.puts("  Usage: dustctl join <peer_ip> <token>")
        1

      [] ->
        Formatter.error("Missing peer IP and invite token")
        IO.puts("  Usage: dustctl join <peer_ip> <token>")
        IO.puts("")
        IO.puts("  Get an invite by running 'dustctl invite' on an existing node.")
        1
    end
  end
end
