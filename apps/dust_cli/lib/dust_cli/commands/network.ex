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
    Formatter.heading("Tailscale Authentication")
    IO.puts("")

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

        # If no auth URL yet, poll a bit — the sidecar may still be starting up
        auth_url =
          if auth_url do
            auth_url
          else
            Formatter.info("Checking for login URL...")
            poll_for_auth_url(config, 15)
          end

        if auth_url do
          # ── Auth URL available — show it prominently ──
          IO.puts("")
          IO.puts("  Visit this link to authenticate with Tailscale:")
          IO.puts("")
          IO.puts("    \e[1;4;36m#{auth_url}\e[0m")
          IO.puts("")
          Formatter.info("Waiting for authentication (press Ctrl+C to cancel)...")
          IO.puts("")

          case poll_for_auth(config, 120) do
            :ok ->
              Formatter.success("Authentication successful!")
              IO.puts("")

              case Client.get(config, "/api/v1/status") do
                {200, {:ok, %{"network" => updated_net}}} ->
                  display_network(updated_net)

                _ ->
                  :ok
              end

              0

            :timeout ->
              Formatter.warning("Timed out waiting for authentication.")
              IO.puts("  You can re-run 'dustctl auth' to check again.")
              1
          end
        else
          # ── No auth URL available after polling — provide manual instructions ──
          IO.puts("")
          IO.puts("  Could not retrieve a login URL from the daemon.")
          IO.puts("  This can happen if the sidecar hasn't started yet.")
          IO.puts("")
          IO.puts("  #{bold("Option 1:")} Set TS_AUTHKEY and restart:")
          IO.puts("")
          IO.puts("    #{bold("export TS_AUTHKEY=\"tskey-auth-...\"")}")
          IO.puts("    #{bold("dustctl daemon stop && dustctl daemon start")}")
          IO.puts("")
          IO.puts("  #{bold("Option 2:")} Check the daemon logs for a login URL:")
          IO.puts("")
          IO.puts("    #{bold("journalctl -u dust -f")}     (systemd)")
          IO.puts("    #{bold("log stream --predicate 'process == \"dust\"'")}  (macOS)")
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
        Formatter.heading("Network Status")
        IO.puts("")

        connected = net["connected"] == true
        state = net["state"] || "unknown"
        auth_url = net["auth_url"]

        state_display =
          case state do
            "authenticated" -> "🟢 authenticated"
            "needs_login" -> "🟡 needs login"
            "connecting" -> "⏳ connecting"
            other -> "⚠ #{other}"
          end

        pairs = [
          {"Tailscale", state_display},
          {"Self IP", net["self_ip"] || "—"},
          {"Tailscale Peers", net["tailscale_peers"] || 0},
          {"System Ready", if(ready, do: "✓ yes", else: "⏳ no")}
        ]

        # Add auth URL row if present
        pairs =
          if auth_url do
            pairs ++ [{"Auth URL", auth_url}]
          else
            pairs
          end

        Formatter.kv(pairs)

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

    case prompt("  Remove Tailscale state and restart? [y/N]") do
      "y" ->
        # Remove the Tailscale state directory
        data_dir = config.data_dir
        ts_state = Path.join(data_dir, "ts_state")

        if File.exists?(ts_state) do
          File.rm_rf!(ts_state)
          Formatter.success("Removed Tailscale state at #{ts_state}")
        end

        Formatter.info("Restart the daemon to complete logout:")
        IO.puts("    #{bold("dustctl daemon stop && dustctl daemon start")}")
        0

      _ ->
        Formatter.info("Cancelled.")
        0
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp display_network(net) do
    Formatter.kv([
      {"Status", "🟢 authenticated"},
      {"Self IP", net["self_ip"] || "—"},
      {"Tailscale Peers", net["tailscale_peers"] || 0}
    ])
  end

  defp poll_for_auth_url(_config, remaining) when remaining <= 0 do
    IO.puts("")
    nil
  end

  defp poll_for_auth_url(config, remaining) do
    :timer.sleep(2_000)
    IO.write(".")

    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"network" => %{"auth_url" => url}}}} when is_binary(url) and url != "" ->
        IO.puts("")
        url

      {200, {:ok, %{"network" => %{"connected" => true}}}} ->
        # Already connected while we were polling
        IO.puts("")
        nil

      _ ->
        poll_for_auth_url(config, remaining - 2)
    end
  end

  defp poll_for_auth(_config, remaining) when remaining <= 0, do: :timeout

  defp poll_for_auth(config, remaining) do
    :timer.sleep(2_000)

    # Print a dot to show progress
    IO.write(".")

    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"network" => %{"connected" => true}}}} ->
        IO.puts("")
        :ok

      _ ->
        poll_for_auth(config, remaining - 2)
    end
  end

  defp show_auth_instructions do
    IO.puts("  #{bold("How to get a TS_AUTHKEY:")}")
    IO.puts("")
    IO.puts("  1. Go to https://login.tailscale.com/admin/settings/keys")
    IO.puts("  2. Generate a new auth key")
    IO.puts("  3. Enable Tags → select 'tag:dust-node'")
    IO.puts("  4. Enable Pre-approved (if device approval is on)")
    IO.puts("  5. Copy the key and set it:")
    IO.puts("")
    IO.puts("     #{bold("export TS_AUTHKEY=\"tskey-auth-...\"")}")
    IO.puts("")
  end

  defp prompt(message) do
    IO.write("#{message} ")
    IO.read(:stdio, :line) |> String.trim()
  end

  defp bold(text), do: "\e[1m#{text}\e[0m"
end
