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

    case Client.post(config, "/api/v1/service/install") do
      {200, _} ->
        Formatter.success("Service installed. It will start automatically on next reboot.")
        0

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
end
