defmodule Dust.CLI.Commands.Daemon do
  @moduledoc """
  Handles daemon lifecycle commands:

      dustctl daemon start
      dustctl daemon stop
      dustctl daemon status
      dustctl daemon install
      dustctl daemon uninstall
  """

  alias Dust.CLI.{Client, Formatter}

  @doc """
  Restarts the daemon so a freshly-chosen node name takes effect.

  Erlang's node identity (`Node.self()`) is fixed for the life of the VM —
  it's built once at boot from `RELEASE_NODE`, which the release's boot
  script derives from the `node_name` file. Renaming the node only writes
  new values to `config.yaml` and that file; the *running* VM keeps
  answering to its old identity until it's actually restarted. Used by
  `dustctl init` right after the node-name step, before unlock/Tailscale/
  network setup — those all assume `Node.self()` already matches the
  chosen name.

  Restarts by shelling out directly from this CLI process — never by
  asking the daemon's own `/api/v1/service/*` API to restart itself: that
  handler runs `systemctl stop dust` synchronously, and if it ran inside
  a request handled *by* the process being stopped, the command would
  block waiting for this same process to exit while this process is
  blocked waiting on the command. The CLI is a separate OS process, so it
  can issue and wait on these commands safely.

  Returns `:ok` once the daemon answers again, or `{:error, reason}` if
  the restart could not be confirmed within the timeout — callers should
  fall back to telling the user to restart manually and re-run `init`.
  """
  @spec restart_for_rename(map()) :: :ok | {:error, term()}
  def restart_for_rename(config) do
    with :ok <- do_restart(service_mode(config)) do
      wait_ready(config, 30)
    end
  end

  # Only a systemd/launchd/WinSW-managed daemon is *actually* running.
  # Anything else (not installed, or the status check itself fails) means
  # this daemon was started directly (e.g. `dustctl daemon start`), so the
  # release binary's own stop/start is the right tool.
  defp service_mode(config) do
    case Client.get(config, "/api/v1/service/status") do
      {200, {:ok, %{"status" => "running"}}} -> :service
      _ -> :manual
    end
  end

  defp do_restart(:service) do
    case :os.type() do
      {:unix, :linux} -> run_and_check("sudo", ["systemctl", "restart", "dust"])
      {:unix, :darwin} -> restart_launchd()
      {:win32, _} -> restart_winsw()
      other -> {:error, {:unsupported_os, other}}
    end
  end

  defp do_restart(:manual) do
    case find_release_bin() do
      nil ->
        {:error, :release_binary_not_found}

      release_bin ->
        # Best-effort: a fresh first-time-setup daemon is expected to
        # already be running, so a failed "stop" here (e.g. it wasn't up
        # for some reason) shouldn't block the restart attempt.
        _ = System.cmd(release_bin, ["stop"], stderr_to_stdout: true)
        run_and_check(release_bin, ["start"])
    end
  end

  defp restart_launchd do
    plist = Path.join(System.user_home!(), "Library/LaunchAgents/com.dust.daemon.plist")
    _ = System.cmd("launchctl", ["unload", plist], stderr_to_stdout: true)
    run_and_check("launchctl", ["load", plist])
  end

  defp restart_winsw do
    _ = System.cmd("net", ["stop", "dust"], stderr_to_stdout: true)
    run_and_check("net", ["start", "dust"])
  end

  defp run_and_check(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:command_failed, cmd, args, code, output}}
    end
  rescue
    e -> {:error, {:command_error, cmd, Exception.message(e)}}
  end

  def run(config, ["start" | _]) do
    Formatter.info("Starting the Dust daemon...")

    release_bin = find_release_bin()

    if release_bin do
      case System.cmd(release_bin, ["start"], stderr_to_stdout: true) do
        {_output, 0} ->
          Formatter.success("Daemon started")

          Owl.Spinner.start(id: :daemon_ready, labels: [processing: "Waiting for daemon to become ready..."])

          case wait_ready(config, 30) do
            :ok ->
              Formatter.spinner_stop(id: :daemon_ready, resolution: :ok, label: "Daemon is ready")

            :timeout ->
              Formatter.spinner_stop(id: :daemon_ready, resolution: :error, label: "Daemon started but readiness check timed out")
          end

          0

        {output, code} ->
          Formatter.error("Failed to start daemon (exit #{code})")
          IO.puts(output)
          1
      end
    else
      Formatter.error("Release binary not found")
      IO.puts("")
      IO.puts("  Build a release first:")
      Owl.IO.puts(["    ", Owl.Data.tag("MIX_ENV=prod mix release dust", :bright)])
      IO.puts("")
      IO.puts("  Or start in development mode:")
      Owl.IO.puts(["    ", Owl.Data.tag("iex -S mix", :bright)])
      1
    end
  end

  def run(_config, ["stop" | _]) do
    Formatter.info("Stopping the Dust daemon...")

    release_bin = find_release_bin()

    if release_bin do
      case System.cmd(release_bin, ["stop"], stderr_to_stdout: true) do
        {_output, 0} ->
          Formatter.success("Daemon stopped")
          0

        {output, code} ->
          Formatter.error("Failed to stop daemon (exit #{code})")
          IO.puts(output)
          1
      end
    else
      Formatter.error("Release binary not found")
      1
    end
  end

  def run(config, ["status" | _]) do
    case Client.ping(config) do
      :ok ->
        Formatter.success("Daemon is running on #{config.host}:#{config.port}")
        0

      :error ->
        Formatter.error("Daemon is not running")
        1
    end
  end

  def run(config, ["install" | _]) do
    Formatter.info("Installing Dust as a system service...")

    case Client.post(config, "/api/v1/service/install") do
      {200, _} ->
        Formatter.success("Service installed. It will start automatically on next reboot.")
        0

      {_status, {:ok, %{"error" => "nixos_managed"}}} ->
        print_nixos_managed()
        1

      {_status, {:ok, %{"error" => reason}}} ->
        Formatter.error("Install failed: #{reason}")
        1

      {:error, _} ->
        Formatter.error("Could not reach daemon. Make sure it is running first.")
        1
    end
  end

  def run(config, ["uninstall" | _]) do
    Formatter.info("Removing Dust system service...")

    case Client.delete(config, "/api/v1/service/uninstall") do
      {200, _} ->
        Formatter.success("Service removed.")
        0

      {_status, {:ok, %{"error" => "nixos_managed"}}} ->
        print_nixos_managed()
        1

      {_status, {:ok, %{"error" => reason}}} ->
        Formatter.error("Uninstall failed: #{reason}")
        1

      {:error, _} ->
        Formatter.error("Could not reach daemon. Make sure it is running first.")
        1
    end
  end

  def run(_config, args) do
    Formatter.error("Unknown daemon command: #{Enum.join(args, " ")}")
    IO.puts("")
    IO.puts("  Usage: dustctl daemon <start|stop|status|install|uninstall>")
    1
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp find_release_bin do
    candidates = [
      Path.expand("../dust", System.get_env("ESCRIPT_PATH") || "."),
      "/usr/local/bin/dust",
      Path.expand("_build/prod/rel/dust/bin/dust"),
      "bin/dust"
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        # A Nix-installed daemon (e.g. via the flake overlay) doesn't sit
        # at any of the paths above — it's a store path exposed on PATH.
        System.find_executable("dust")

      path ->
        path
    end
  end

  defp wait_ready(_config, 0), do: :timeout

  defp wait_ready(config, retries) do
    :timer.sleep(1_000)

    case Client.ping(config) do
      :ok -> :ok
      :error -> wait_ready(config, retries - 1)
    end
  end

  defp print_nixos_managed do
    Formatter.error("Dust is managed declaratively on NixOS.")
    IO.puts("")
    IO.puts("  Add the following to your NixOS configuration:")
    IO.puts("")
    Owl.IO.puts(["    ", Owl.Data.tag("services.dust.enable = true;", :bright)])
    IO.puts("")
    IO.puts("  Using the flake module:")
    IO.puts("")

    Owl.IO.puts([
      "    ",
      Owl.Data.tag("imports = [ inputs.dust.nixosModules.default ];", :bright)
    ])

    IO.puts("")
    IO.puts("  See README.md#nixos for full instructions.")
  end
end
