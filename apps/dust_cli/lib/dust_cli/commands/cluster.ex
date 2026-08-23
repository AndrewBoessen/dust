defmodule Dust.CLI.Commands.Cluster do
  @moduledoc """
  Handles cluster management:

      dustctl nodes
      dustctl invite
      dustctl join IP TOKEN [--force]
  """

  alias Dust.CLI.{Client, Formatter}

  # ── nodes ──────────────────────────────────────────────────────────────

  def nodes(config, _args) do
    case Client.get(config, "/api/v1/nodes") do
      {200, {:ok, %{"nodes" => nodes}}} ->
        display_nodes(nodes)
        0

      other ->
        Formatter.api_error(other)
    end
  end

  defp display_nodes(nodes) do
    IO.puts("")
    headers = ["Node", "Status", "Fitness", "Role"]

    rows =
      Enum.map(nodes, fn node ->
        status = if node["online"], do: "online", else: "offline"
        role = if node["self"], do: "this node", else: ""
        fitness = format_fitness(node["fitness"])
        [node["name"], status, fitness, role]
      end)

    Formatter.table(headers, rows)
    IO.puts("")
    Formatter.dim("#{length(nodes)} total node(s)")
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
        Formatter.info_box("Join Command", [
          "To join this network from another machine:\n\n",
          Owl.Data.tag("  dustctl join #{body["join_ip"]} #{body["token"]}", [:bright, :cyan]),
          "\n\n",
          Owl.Data.tag("! ", :yellow),
          "One-time use · expires in 10 minutes"
        ])
        IO.puts("")
        0

      {423, {:ok, %{"error" => "keystore_locked"}}} ->
        Formatter.error("Key store is locked")
        IO.puts("  Run 'dustctl unlock' before issuing an invite.")
        1

      {_, {:ok, %{"error" => reason}}} ->
        Formatter.error("Failed to create invite: #{reason}")
        1

      other ->
        Formatter.api_error(other)
    end
  end

  # ── join ───────────────────────────────────────────────────────────────

  def join(config, args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [force: :boolean])

    case rest do
      [peer_ip, token | _] ->
        Formatter.info("Joining network at #{peer_ip}...")
        do_join(config, peer_ip, token, Keyword.get(opts, :force, false))

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

  # ── join helpers ───────────────────────────────────────────────────────

  defp do_join(config, peer_ip, token, force?) do
    body = %{peer_address: peer_ip, token: token, force: force?}

    case Client.post(config, "/api/v1/join", body) do
      {200, {:ok, %{"status" => "joined"} = response}} ->
        Formatter.success("Joined the network via #{peer_ip}")
        report_master_key(response["master_key"])
        IO.puts("")
        Formatter.info("Run 'dustctl nodes' to see cluster peers.")
        0

      {409, {:ok, %{"error" => "local_data_exists", "local_data" => local_data}}} ->
        if confirm_key_overwrite(local_data) do
          IO.puts("")
          do_join(config, peer_ip, token, true)
        else
          Formatter.info("Join cancelled — nothing was changed.")
          1
        end

      {409, {:ok, %{"error" => "key_store_locked"}}} ->
        Formatter.error("The key store is locked")
        Formatter.info("Run 'dustctl unlock' first so the network's master key can be adopted.")
        1

      {_, {:ok, %{"error" => reason}}} ->
        Formatter.error("Join failed: #{reason}")
        1

      other ->
        Formatter.api_error(other)
    end
  end

  defp report_master_key("adopted"),
    do: Formatter.success("Adopted the network's master key")

  defp report_master_key("deferred"),
    do:
      Formatter.info(
        "Run 'dustctl unlock' with the network password to adopt the network's master key."
      )

  defp report_master_key(_), do: :ok

  @doc """
  Warns that adopting the network's master key orphans local data and asks
  the user whether to go ahead. Shared with the `dustctl init` wizard.
  """
  @spec confirm_key_overwrite(map()) :: boolean()
  def confirm_key_overwrite(local_data) do
    IO.puts("")

    Formatter.warning("This node already holds data encrypted with its own master key")

    IO.puts("")
    Formatter.kv(describe_local_data(local_data))
    IO.puts("")
    IO.puts("  Joining adopts the network's master key. Data stored under this")
    IO.puts("  node's current key becomes permanently unreadable.")
    IO.puts("")

    Owl.IO.confirm(message: "Adopt the network's master key anyway?", default: false)
  end

  defp describe_local_data(%{"shards" => "unknown"}), do: [{"Local data", "could not be read"}]

  defp describe_local_data(local_data) when is_map(local_data) do
    [
      {"Stored shards", to_string(local_data["shards"] || 0)},
      {"Files", to_string(local_data["files"] || 0)}
    ]
  end

  defp describe_local_data(_), do: [{"Local data", "could not be read"}]
end
