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
        IO.puts("  Start the daemon before continuing:")
        IO.puts("    • From a release: #{bold("bin/dust start")}")
        IO.puts("    • Development:    #{bold("iex -S mix")}")
        IO.puts("")

        case prompt("Start the daemon now? (requires release binary) [y/N]") do
          "y" ->
            Dust.CLI.Commands.Daemon.run(config, ["start"])

            IO.puts("  Waiting for daemon to become ready...")
            wait_for_daemon(config, 30)

          _ ->
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
        password = prompt_password("  Enter password (creates new key on first use): ")

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
    IO.puts("  Choose how to configure networking:")
    IO.puts("")
    IO.puts("    #{bold("1")}  Create a new Dust network (first node)")
    IO.puts("    #{bold("2")}  Join an existing Dust network")
    IO.puts("    #{bold("3")}  Skip network setup (configure later)")
    IO.puts("")

    case prompt("  Select [1/2/3]") do
      "1" ->
        setup_new_network(config)

      "2" ->
        setup_join_network(config)

      _ ->
        Formatter.info("Skipped network setup. Configure Tailscale and run 'dustctl join' later.")
    end

    IO.puts("")
    Formatter.heading("Setup Complete")
    IO.puts("")
    IO.puts("  Your Dust node is ready. Useful commands:")
    IO.puts("")
    IO.puts("    #{bold("dustctl status")}          Check node status")
    IO.puts("    #{bold("dustctl ls")}              List files")
    IO.puts("    #{bold("dustctl upload FILE")}     Upload a file")
    IO.puts("    #{bold("dustctl nodes")}           List cluster peers")
    IO.puts("    #{bold("dustctl help")}            Full command reference")
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
    IO.puts("    #{bold("dustctl invite")}")
    IO.puts("")
    IO.puts("  Then on the joining machine:")
    IO.puts("")
    IO.puts("    #{bold("dustctl join <this-node-ip> <token>")}")

    # Create the root directory in the filesystem
    case Client.post(config, "/api/v1/fs/mkdir", %{parent_id: nil, name: "/"}) do
      {201, {:ok, %{"dir_id" => dir_id}}} ->
        Formatter.success("Created root directory: #{dir_id}")

      {400, _} ->
        Formatter.dim("  Root directory may already exist.")

      _ ->
        :ok
    end
  end

  # ── Join network ───────────────────────────────────────────────────────

  defp setup_join_network(config) do
    IO.puts("")
    peer_ip = prompt("  Enter the Tailscale IP of the node to join")
    token = prompt("  Enter the invite token")

    if peer_ip == "" or token == "" do
      Formatter.error("Both peer IP and token are required.")
    else
      IO.puts("")
      Formatter.spinner("Joining network at #{peer_ip}")

      case Client.post(config, "/api/v1/join", %{peer_address: peer_ip, token: token}) do
        {200, {:ok, %{"status" => "joined"}}} ->
          Formatter.spinner_done()
          Formatter.success("Successfully joined the network via #{peer_ip}")

        {_, {:ok, %{"error" => reason}}} ->
          Formatter.spinner_done()
          Formatter.error("Failed to join: #{reason}")

        {:error, reason} ->
          Formatter.spinner_done()
          Formatter.error("Connection error: #{inspect(reason)}")
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp wait_for_daemon(_config, 0) do
    Formatter.error("Daemon did not become ready in time.")
  end

  defp wait_for_daemon(config, retries) do
    :timer.sleep(1_000)

    case Client.ping(config) do
      :ok -> Formatter.success("Daemon is now running")
      :error -> wait_for_daemon(config, retries - 1)
    end
  end

  defp prompt(message) do
    IO.write("#{message} ")
    IO.read(:stdio, :line) |> String.trim()
  end

  defp prompt_password(message) do
    IO.write(message)

    case :io.get_password() do
      {:error, _} ->
        IO.gets("") |> String.trim()

      password when is_list(password) ->
        to_string(password) |> String.trim()

      password when is_binary(password) ->
        String.trim(password)
    end
  end

  defp bold(text), do: "\e[1m#{text}\e[0m"

  defp return_code(code) do
    System.halt(code)
  end
end
