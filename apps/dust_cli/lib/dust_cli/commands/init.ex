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

          Owl.Spinner.start(id: :daemon_ready, labels: [processing: "Waiting for daemon..."])

          case wait_for_daemon(config, 30) do
            :ok ->
              Formatter.spinner_stop(id: :daemon_ready, resolution: :ok, label: "Daemon is ready")

            :timeout ->
              Formatter.spinner_stop(id: :daemon_ready, resolution: :error, label: "Daemon did not become ready in time")
              return_code(1)
          end
        else
          Formatter.info("Skipping daemon start. Run 'dustctl init' again once the daemon is running.")
          return_code(1)
        end
    end

    IO.puts("")

    # Step 3: Node name (must happen BEFORE Tailscale starts — changing
    # the name later forces a re-auth because Tailscale identity is keyed
    # by hostname).
    setup_node_name(config)

    IO.puts("")

    # Step 4: Unlock key store
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

          {401, {:ok, %{"error" => "invalid_password"}}} ->
            Formatter.error("Wrong password — a key already exists at #{config.data_dir}/master.key")
            Formatter.info("To start fresh, delete that file and run 'dustctl init' again.")
            return_code(1)

          {401, {:ok, %{"error" => "unauthorized"}}} ->
            Formatter.error("API token invalid — cannot authenticate to the daemon")
            Formatter.info("Check that #{config.data_dir}/api_token exists and is readable by your user.")
            return_code(1)

          {401, _} ->
            Formatter.error("Authentication failed (401)")
            return_code(1)

          other ->
            Formatter.api_error(other)
            return_code(1)
        end

      _ ->
        Formatter.warning("Cannot check key store status (daemon may not be ready)")
    end

    IO.puts("")

    # Step 5: Bring up Tailscale now that node_name is finalized.
    start_network(config)

    IO.puts("")

    # Step 6: Network setup
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

  # ── Node name ──────────────────────────────────────────────────────────

  defp setup_node_name(config) do
    Formatter.heading("Node Name")
    IO.puts("")

    current =
      case Client.get(config, "/api/v1/config") do
        {200, {:ok, %{"config" => %{"node_name" => name}}}} when is_binary(name) and name != "" ->
          name

        _ ->
          "dust"
      end

    IO.puts("  This is the short name used as the Erlang node prefix (e.g. <name>@<ip>).")
    IO.puts("  Allowed: letters, digits, '-' and '_'. Press Enter to keep the current value.")
    IO.puts("")

    chosen =
      Owl.IO.input(label: "Node name [#{current}]", optional: true)
      |> case do
        nil -> current
        "" -> current
        val -> String.trim(val)
      end

    cond do
      chosen == current ->
        Formatter.dim("  Keeping current node name: #{current}")

      not valid_node_name?(chosen) ->
        Formatter.error("Invalid node name '#{chosen}'.")
        Formatter.info("Must be 1-63 chars, start with a letter/digit, contain only letters, digits, '-' or '_'.")

      true ->
        case Client.put(config, "/api/v1/config", %{node_name: chosen}) do
          {200, _} ->
            Formatter.success("Node name set to '#{chosen}'")
            Formatter.dim("  Takes effect on next daemon restart.")

          {_, {:ok, %{"results" => results}}} ->
            Formatter.error("Failed to set node name: #{inspect(results[to_string(:node_name)])}")

          other ->
            Formatter.api_error(other)
        end
    end
  end

  defp valid_node_name?(name) when is_binary(name) do
    Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,62}\z/, name)
  end

  defp valid_node_name?(_), do: false

  # ── Bring up Tailscale ────────────────────────────────────────────────

  defp start_network(config) do
    IO.puts("  Starting Tailscale…")

    case Client.post(config, "/api/v1/network/start", %{}) do
      {200, _} ->
        Formatter.success("Tailscale sidecar started")
        IO.puts("")
        wait_for_tailscale(config)

      other ->
        Formatter.warning("Could not start Tailscale sidecar: #{inspect(other)}")
        Formatter.info("You may need to run 'dustctl init' again after fixing the issue.")
    end
  end

  # Cold-starting the Go sidecar (load tsnet state, register with control
  # plane, mint a login URL) routinely takes 15–45 s. Poll long enough to
  # surface either the auth URL or the connected state inline so the user
  # doesn't have to follow up with `dustctl auth`.
  @tailscale_poll_total_s 45
  @tailscale_poll_interval_ms 2_000

  defp wait_for_tailscale(config) do
    Owl.Spinner.start(id: :ts_init, labels: [processing: "Reaching Tailscale…"])

    case poll_tailscale(config, @tailscale_poll_total_s) do
      {:authenticated, self_ip} ->
        Formatter.spinner_stop(id: :ts_init, resolution: :ok, label: "Tailscale connected (#{self_ip})")
        :ok

      {:auth_url, url} ->
        Formatter.spinner_stop(id: :ts_init, resolution: :ok, label: "Tailscale auth URL is ready")
        IO.puts("")

        Formatter.info_box("Tailscale Auth", [
          "Open this URL on any device to authenticate this node:\n\n",
          Owl.Data.tag("  " <> url, [:cyan, :underline])
        ])

        IO.puts("")
        Formatter.info("Run 'dustctl auth' to wait for authentication.")
        :ok

      :still_starting ->
        Formatter.spinner_stop(id: :ts_init, resolution: :error, label: "Tailscale did not respond in time")
        Formatter.info("Run 'dustctl auth' shortly to retrieve the login URL.")
        :ok
    end
  end

  defp poll_tailscale(_config, remaining_s) when remaining_s <= 0, do: :still_starting

  defp poll_tailscale(config, remaining_s) do
    :timer.sleep(@tailscale_poll_interval_ms)

    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"network" => %{"connected" => true, "self_ip" => ip}}}}
      when is_binary(ip) and ip != "" ->
        {:authenticated, ip}

      {200, {:ok, %{"network" => %{"auth_url" => url}}}}
      when is_binary(url) and url != "" ->
        {:auth_url, url}

      _ ->
        poll_tailscale(config, remaining_s - div(@tailscale_poll_interval_ms, 1_000))
    end
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
      join_network(config, peer_ip, token, false)
    end
  end

  defp join_network(config, peer_ip, token, force?) do
    Owl.Spinner.start(id: :join, labels: [processing: "Joining network at #{peer_ip}..."])

    case Client.post(config, "/api/v1/join", %{
           peer_address: peer_ip,
           token: token,
           force: force?
         }) do
      {200, {:ok, %{"status" => "joined"} = response}} ->
        Formatter.spinner_stop(id: :join, resolution: :ok, label: "Joined network via #{peer_ip}")
        report_master_key(response["master_key"])

      {409, {:ok, %{"error" => "local_data_exists", "local_data" => local_data}}} ->
        Formatter.spinner_stop(id: :join, resolution: :error, label: "Join needs confirmation")

        if Dust.CLI.Commands.Cluster.confirm_key_overwrite(local_data) do
          IO.puts("")
          join_network(config, peer_ip, token, true)
        else
          Formatter.info("Join cancelled — nothing was changed.")
        end

      {409, {:ok, %{"error" => "key_store_locked"}}} ->
        Formatter.spinner_stop(id: :join, resolution: :error, label: "Key store is locked")
        Formatter.info("Run 'dustctl unlock', then 'dustctl join #{peer_ip} <token>'.")

      {_, {:ok, %{"error" => reason}}} ->
        Formatter.spinner_stop(id: :join, resolution: :error, label: "Failed to join: #{reason}")

      {:error, {:failed_connect, _}} ->
        Formatter.spinner_stop(id: :join, resolution: :error, label: "Cannot connect to the daemon")

      {:error, {:timeout, _}} ->
        Formatter.spinner_stop(id: :join, resolution: :error, label: "Request timed out")

      {:error, _reason} ->
        Formatter.spinner_stop(id: :join, resolution: :error, label: "Connection error — is the daemon running?")
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
