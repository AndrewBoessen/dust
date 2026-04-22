defmodule Dust.CLI.Commands.Init do
  @moduledoc """
  First-time setup wizard for the Dust daemon.

  Guides the user through:
  1. Creating the data directory
  2. Starting the daemon
  3. Unlocking / creating the key store
  4. Creating a new network or joining an existing one
  """

  alias Dust.CLI.{Client, Formatter}

  def run(config, _args) do
    Formatter.heading("Dust — First-Time Setup")
    IO.puts("")

    # Step 1: Data directory
    data_dir = config.data_dir
    IO.puts("  Data directory: #{data_dir}")

    if File.exists?(data_dir) do
      Formatter.dim("  Directory already exists.")
    else
      IO.puts("  Creating data directory...")
      File.mkdir_p!(data_dir)
      Formatter.success("Created #{data_dir}")
    end

    IO.puts("")

    # Step 2: Check daemon
    IO.puts("  Checking daemon status...")

    case Client.ping(config) do
      :ok ->
        Formatter.success("Daemon is running")

      :error ->
        Formatter.warning("Daemon is not running")
        IO.puts("")
        Owl.IO.puts(["  Start the daemon before continuing:\n",
                     "    • From a release: ", Owl.Data.tag("bin/dust start", :bright), "\n",
                     "    • Development:    ", Owl.Data.tag("iex -S mix", :bright)])
        IO.puts("")

        if Owl.IO.confirm(message: "Start the daemon now? (requires release binary)", default: false) do
          Dust.CLI.Commands.Daemon.run(config, ["start"])

          Owl.Spinner.start(id: :daemon_ready, labels: %{processing: "Waiting for daemon..."})

          case wait_for_daemon(config, 30) do
            :ok ->
              Owl.Spinner.stop(id: :daemon_ready, resolution: :ok, label: "Daemon is ready")

            :timeout ->
              Owl.Spinner.stop(id: :daemon_ready, resolution: :error, label: "Daemon did not become ready in time")
              return_code(1)
          end
        else
          Formatter.info("Skipping daemon start. Run 'dustctl init' again once the daemon is running.")
          return_code(1)
        end
    end

    IO.puts("")

    # Step 3: Unlock key store
    IO.puts("  Checking key store...")

    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"key_store" => "unlocked"}}} ->
        Formatter.success("Key store is already unlocked")

      {200, {:ok, %{"key_store" => "locked"}}} ->
        IO.puts("")
        password = Owl.IO.input(label: "Password (creates new key on first use)", secret: true)

        case Client.post(config, "/api/v1/unlock", %{password: password}) do
          {200, {:ok, %{"status" => status}}} ->
            Formatter.success("Key store #{status}")

          {401, _} ->
            Formatter.error("Invalid password")
            return_code(1)

          other ->
            Formatter.error("Failed to unlock: #{inspect(other)}")
            return_code(1)
        end

      _ ->
        Formatter.warning("Cannot check key store status (daemon may not be ready)")
    end

    IO.puts("")

    # Step 4: Network setup
    Formatter.heading("Network Setup")
    IO.puts("")

    choice =
      Owl.IO.select(
        ["Create a new network (first node)", "Join an existing network", "Skip"],
        label: "Network setup"
      )

    case choice do
      "Create a new network (first node)" ->
        setup_new_network(config)

      "Join an existing network" ->
        setup_join_network(config)

      _ ->
        Formatter.info("Skipped network setup. Configure Tailscale and run 'dustctl join' later.")
    end

    IO.puts("")
    Formatter.heading("Setup Complete")
    IO.puts("")
    IO.puts("  Your Dust node is ready. Useful commands:")
    IO.puts("")
    Owl.IO.puts(["    ", Owl.Data.tag("dustctl status", :bright), "          Check node status"])
    Owl.IO.puts(["    ", Owl.Data.tag("dustctl ls", :bright), "              List files"])
    Owl.IO.puts(["    ", Owl.Data.tag("dustctl upload FILE", :bright), "     Upload a file"])
    Owl.IO.puts(["    ", Owl.Data.tag("dustctl nodes", :bright), "           List cluster peers"])
    Owl.IO.puts(["    ", Owl.Data.tag("dustctl help", :bright), "            Full command reference"])
    IO.puts("")

    0
  end

  # ── New network ────────────────────────────────────────────────────────

  defp setup_new_network(config) do
    IO.puts("")
    IO.puts("  Setting up a new Dust network.")
    IO.puts("")
    IO.puts("  Ensure you have configured Tailscale ACLs and tags as described")
    IO.puts("  in the README. Set TS_AUTHKEY or use interactive login.")
    IO.puts("")

    Formatter.success("This node is the genesis node of a new network.")
    IO.puts("")
    IO.puts("  To add other nodes, run on this machine:")
    IO.puts("")
    Owl.IO.puts(["    ", Owl.Data.tag("dustctl invite", :bright)])
    IO.puts("")
    IO.puts("  Then on the joining machine:")
    IO.puts("")
    Owl.IO.puts(["    ", Owl.Data.tag("dustctl join <this-node-ip> <token>", :bright)])

    case Client.post(config, "/api/v1/fs/mkdir", %{parent_id: nil, name: "/"}) do
      {201, {:ok, %{"dir_id" => dir_id}}} ->
        Formatter.success("Created root directory: #{dir_id}")
        save_root_dir_id(config, dir_id)

      {409, {:ok, %{"dir_id" => dir_id}}} ->
        Formatter.dim("  Root directory already exists.")
        save_root_dir_id(config, dir_id)

      _ ->
        :ok
    end
  end

  # ── Join network ───────────────────────────────────────────────────────

  defp setup_join_network(config) do
    IO.puts("")
    peer_ip = Owl.IO.input(label: "Tailscale IP of the node to join")
    token = Owl.IO.input(label: "Invite token")

    if peer_ip == "" or token == "" do
      Formatter.error("Both peer IP and token are required.")
    else
      IO.puts("")
      Owl.Spinner.start(id: :join, labels: %{processing: "Joining network at #{peer_ip}..."})

      case Client.post(config, "/api/v1/join", %{peer_address: peer_ip, token: token}) do
        {200, {:ok, %{"status" => "joined"}}} ->
          Owl.Spinner.stop(id: :join, resolution: :ok, label: "Joined network via #{peer_ip}")

        {_, {:ok, %{"error" => reason}}} ->
          Owl.Spinner.stop(id: :join, resolution: :error, label: "Failed to join: #{reason}")

        {:error, reason} ->
          Owl.Spinner.stop(id: :join, resolution: :error, label: "Connection error: #{inspect(reason)}")
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp save_root_dir_id(config, dir_id) do
    case Client.put(config, "/api/v1/config", %{root_dir_id: dir_id}) do
      {200, _} -> Formatter.success("Saved root directory ID to configuration")
      _ -> Formatter.warning("Failed to save root directory ID to configuration")
    end
  end

  defp wait_for_daemon(_config, 0), do: :timeout

  defp wait_for_daemon(config, retries) do
    :timer.sleep(1_000)

    case Client.ping(config) do
      :ok -> :ok
      :error -> wait_for_daemon(config, retries - 1)
    end
  end

  defp return_code(code) do
    System.halt(code)
  end
end
