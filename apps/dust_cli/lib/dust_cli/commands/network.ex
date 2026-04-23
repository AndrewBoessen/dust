defmodule Dust.CLI.Commands.Network do
  @moduledoc """
  Handles Tailscale authentication and network connectivity:

      dustctl auth             Check Tailscale status, show auth URL if needed
      dustctl auth status      Show network connectivity details
      dustctl auth logout      Disconnect from Tailscale
  """

  alias Dust.CLI.{Client, Formatter}

  def run(config, ["status" | _]), do: status(config)
  def run(config, ["logout" | _]), do: logout(config)
  def run(config, _args), do: auth(config)

  # ── auth (default) ─────────────────────────────────────────────────────

  defp auth(config) do
    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"network" => %{"connected" => true} = net}}} ->
        Formatter.success("Already connected to Tailscale")
        IO.puts("")
        display_network(net)
        0

      {200, {:ok, %{"network" => %{"connected" => false} = net}}} ->
        state = net["state"] || "unknown"
        auth_url = net["auth_url"]

        Formatter.warning("Not connected to Tailscale (state: #{state})")
        IO.puts("")

        auth_url =
          if auth_url do
            auth_url
          else
            Owl.Spinner.start(id: :auth_poll, labels: [processing: "Checking for login URL..."])
            url = poll_for_auth_url(config, 15)
            spinner_stop(id: :auth_poll, resolution: :ok)
            url
          end

        if auth_url do
          IO.puts("")
          Formatter.info_box("Tailscale Auth", [
            "Visit this link to authenticate:\n\n",
            Owl.Data.tag("  " <> auth_url, [:cyan, :underline])
          ])
          IO.puts("")
          Formatter.info("Waiting for authentication (press Ctrl+C to cancel)...")
          IO.puts("")

          Owl.Spinner.start(id: :auth_wait, labels: [processing: "Waiting for Tailscale authentication..."])

          case poll_for_auth(config, 120) do
            :ok ->
              spinner_stop(id: :auth_wait, resolution: :ok, label: "Authentication successful")
              IO.puts("")

              case Client.get(config, "/api/v1/status") do
                {200, {:ok, %{"network" => updated_net}}} ->
                  display_network(updated_net)

                _ ->
                  :ok
              end

              0

            :timeout ->
              spinner_stop(id: :auth_wait, resolution: :error, label: "Timed out waiting for authentication")
              IO.puts("  You can re-run 'dustctl auth' to check again.")
              1
          end
        else
          IO.puts("")
          Formatter.info_box("Could not retrieve auth URL", [
            "This can happen if the sidecar hasn't started yet.\n\n",
            Owl.Data.tag("Option 1:", :bright), " Set TS_AUTHKEY and restart:\n\n",
            Owl.Data.tag("  export TS_AUTHKEY=\"tskey-auth-...\"", :cyan), "\n",
            Owl.Data.tag("  dustctl daemon stop && dustctl daemon start", :cyan),
            "\n\n",
            Owl.Data.tag("Option 2:", :bright), " Check daemon logs for a login URL:\n\n",
            Owl.Data.tag("  journalctl -u dust -f", :cyan),
            Owl.Data.tag("     (systemd)\n", :faint),
            Owl.Data.tag("  log stream --predicate 'process == \"dust\"'", :cyan),
            Owl.Data.tag("  (macOS)", :faint)
          ])
          IO.puts("")

          show_auth_instructions()
          1
        end

      {:error, {:failed_connect, _}} ->
        Formatter.daemon_unreachable()
        1

      other ->
        Formatter.error("Unexpected response: #{inspect(other)}")
        1
    end
  end

  # ── status ─────────────────────────────────────────────────────────────

  defp status(config) do
    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"network" => net, "ready" => ready}}} ->
        connected = net["connected"] == true
        state = net["state"] || "unknown"
        auth_url = net["auth_url"]

        state_display =
          case state do
            "authenticated" -> "connected"
            "needs_login" -> "needs login"
            "connecting" -> "connecting"
            other -> other
          end

        pairs = [
          {"Tailscale", state_display},
          {"Self IP", net["self_ip"] || "—"},
          {"Tailscale Peers", net["tailscale_peers"] || 0},
          {"System Ready", if(ready, do: "yes", else: "no")}
        ]

        pairs =
          if auth_url do
            pairs ++ [{"Auth URL", auth_url}]
          else
            pairs
          end

        IO.puts("")
        Formatter.kv_box("Network Status", pairs)

        unless connected do
          IO.puts("")
          Formatter.warning("Run 'dustctl auth' to authenticate.")
        end

        if connected, do: 0, else: 1

      {:error, {:failed_connect, _}} ->
        Formatter.daemon_unreachable()
        1

      other ->
        Formatter.error("Unexpected response: #{inspect(other)}")
        1
    end
  end

  # ── logout ─────────────────────────────────────────────────────────────

  defp logout(config) do
    Formatter.warning("Disconnecting from Tailscale requires restarting the daemon")
    IO.puts("  without a TS_AUTHKEY and clearing the Tailscale state.")
    IO.puts("")

    if Owl.IO.confirm(message: "Remove Tailscale state and restart?", default: false) do
      data_dir = config.data_dir
      ts_state = Path.join(data_dir, "ts_state")

      if File.exists?(ts_state) do
        File.rm_rf!(ts_state)
        Formatter.success("Removed Tailscale state at #{ts_state}")
      end

      Formatter.info("Restart the daemon to complete logout:")
      Owl.IO.puts(["    ", Owl.Data.tag("dustctl daemon stop && dustctl daemon start", :bright)])
      0
    else
      Formatter.info("Cancelled.")
      0
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp display_network(net) do
    Formatter.kv_box("Network", [
      {"Status", "connected"},
      {"Self IP", net["self_ip"] || "—"},
      {"Tailscale Peers", net["tailscale_peers"] || 0}
    ])
  end

  defp poll_for_auth_url(_config, remaining) when remaining <= 0, do: nil

  defp poll_for_auth_url(config, remaining) do
    :timer.sleep(2_000)

    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"network" => %{"auth_url" => url}}}} when is_binary(url) and url != "" ->
        url

      {200, {:ok, %{"network" => %{"connected" => true}}}} ->
        nil

      _ ->
        poll_for_auth_url(config, remaining - 2)
    end
  end

  defp poll_for_auth(_config, remaining) when remaining <= 0, do: :timeout

  defp poll_for_auth(config, remaining) do
    :timer.sleep(2_000)

    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"network" => %{"connected" => true}}}} ->
        :ok

      _ ->
        poll_for_auth(config, remaining - 2)
    end
  end

  defp spinner_stop(opts) do
    Owl.Spinner.stop(opts)
  rescue
    _ -> :ok
  end

  defp show_auth_instructions do
    Formatter.info_box("How to get a TS_AUTHKEY", [
      "1. Go to https://login.tailscale.com/admin/settings/keys\n",
      "2. Generate a new auth key\n",
      "3. Enable Tags → select 'tag:dust-node'\n",
      "4. Enable Pre-approved (if device approval is on)\n",
      "5. Copy the key and set it:\n\n",
      Owl.Data.tag("   export TS_AUTHKEY=\"tskey-auth-...\"", :cyan)
    ])
    IO.puts("")
  end
end
