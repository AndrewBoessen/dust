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

  def run(config, ["start" | _]) do
    Formatter.info("Starting the Dust daemon...")

    release_bin = find_release_bin()

    if release_bin do
      case System.cmd(release_bin, ["start"], stderr_to_stdout: true) do
        {_output, 0} ->
          Formatter.success("Daemon started")

          Owl.Spinner.start(id: :daemon_ready, labels: %{processing: "Waiting for daemon to become ready..."})

          case wait_ready(config, 30) do
            :ok ->
              Owl.Spinner.stop(id: :daemon_ready, resolution: :ok, label: "Daemon is ready")

            :timeout ->
              Owl.Spinner.stop(id: :daemon_ready, resolution: :error, label: "Daemon started but readiness check timed out")
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

    case Client.ping(config) do
      :ok ->
        install_service()

      :error ->
        Formatter.warning("Daemon is not running. Installing service template manually...")
        install_service()
    end
  end

  def run(_config, ["uninstall" | _]) do
    Formatter.info("Removing Dust system service...")
    uninstall_service()
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

    Enum.find(candidates, &File.exists?/1)
  end

  defp wait_ready(_config, 0), do: :timeout

  defp wait_ready(config, retries) do
    :timer.sleep(1_000)

    case Client.ping(config) do
      :ok -> :ok
      :error -> wait_ready(config, retries - 1)
    end
  end

  defp install_service do
    case :os.type() do
      {:unix, :linux} -> install_systemd()
      {:unix, :darwin} -> install_launchd()
      {:win32, _} -> install_winsw()
      other ->
        Formatter.error("Unsupported platform: #{inspect(other)}")
        1
    end
  end

  defp uninstall_service do
    case :os.type() do
      {:unix, :linux} -> uninstall_systemd()
      {:unix, :darwin} -> uninstall_launchd()
      {:win32, _} -> uninstall_winsv()
      other ->
        Formatter.error("Unsupported platform: #{inspect(other)}")
        1
    end
  end

  defp install_systemd do
    service_src = find_service_template("linux/dust.service")

    if service_src do
      dest = "/etc/systemd/system/dust.service"

      case System.cmd("sudo", ["cp", service_src, dest], stderr_to_stdout: true) do
        {_, 0} ->
          System.cmd("sudo", ["systemctl", "daemon-reload"])
          System.cmd("sudo", ["systemctl", "enable", "dust"])
          Formatter.success("Installed systemd service at #{dest}")
          Formatter.info("Start with: sudo systemctl start dust")
          0

        {output, _} ->
          Formatter.error("Failed to install: #{output}")
          1
      end
    else
      Formatter.error("Service template not found. Use the template from rel/service/linux/dust.service")
      1
    end
  end

  defp install_launchd do
    service_src = find_service_template("macos/com.dust.daemon.plist")
    dest = Path.join(System.user_home!(), "Library/LaunchAgents/com.dust.daemon.plist")

    if service_src do
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(service_src, dest)
      System.cmd("launchctl", ["load", dest])
      Formatter.success("Installed launchd service at #{dest}")
      0
    else
      Formatter.error("Service template not found")
      1
    end
  end

  defp install_winsw do
    Formatter.info("For Windows, download WinSW and use the template at rel/service/windows/dust-service.xml")
    Formatter.info("See README for detailed instructions.")
    0
  end

  defp uninstall_systemd do
    System.cmd("sudo", ["systemctl", "stop", "dust"], stderr_to_stdout: true)
    System.cmd("sudo", ["systemctl", "disable", "dust"], stderr_to_stdout: true)
    System.cmd("sudo", ["rm", "-f", "/etc/systemd/system/dust.service"], stderr_to_stdout: true)
    System.cmd("sudo", ["systemctl", "daemon-reload"], stderr_to_stdout: true)
    Formatter.success("Removed systemd service")
    0
  end

  defp uninstall_launchd do
    plist = Path.join(System.user_home!(), "Library/LaunchAgents/com.dust.daemon.plist")
    System.cmd("launchctl", ["unload", plist], stderr_to_stdout: true)
    File.rm(plist)
    Formatter.success("Removed launchd service")
    0
  end

  defp uninstall_winsv do
    Formatter.info("Run 'dust-service.exe uninstall' from the install directory")
    0
  end

  defp find_service_template(relative) do
    candidates = [
      Path.expand("rel/service/#{relative}"),
      Path.expand("../rel/service/#{relative}"),
      Path.expand("../../rel/service/#{relative}")
    ]

    Enum.find(candidates, &File.exists?/1)
  end
end
