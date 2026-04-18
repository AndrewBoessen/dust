defmodule Dust.CLI do
  @moduledoc """
  Command-line interface for the Dust distributed file system.

  Communicates with the Dust daemon via its local HTTP API. The daemon
  must be running for most commands to work. Use `dustctl init` for
  first-time setup or `dustctl daemon start` to start the daemon.

  ## Usage

      dustctl <command> [options]

  ## Commands

      init                  First-time setup wizard
      status                Show node status

      auth                  Check Tailscale connection / show auth instructions
      auth status           Detailed network connectivity info
      auth logout           Disconnect from Tailscale

      daemon start          Start the daemon
      daemon stop           Stop the daemon
      daemon status         Check if daemon is running
      daemon install        Install as system service
      daemon uninstall      Remove system service

      unlock                Unlock the key store
      lock                  Lock the key store

      ls [DIR_ID]           List directory contents
      mkdir NAME            Create a directory
      upload FILE           Upload a file
      download ID DEST      Download a file to a local path
      rm ID                 Remove a file or directory

      nodes                 List cluster peers
      invite                Create an invite token
      join IP TOKEN         Join an existing cluster

      config                Show current configuration
      config set KEY VALUE  Update a runtime configuration value

      gc stats              Show garbage collection statistics
      gc sweep              Trigger a manual GC sweep

      help                  Show this help message
      version               Show version

  ## Global Options

      --host HOST           Daemon host (default: 127.0.0.1)
      --port PORT           Daemon port (default: 4884)
      --token TOKEN         API bearer token (default: read from data dir)
      --data-dir DIR        Data directory (default: ~/.dust)
      --no-color            Disable colored output
  """

  alias Dust.CLI.{Client, Formatter, Commands}

  @version "0.1.0"

  # Commands that DO NOT require Tailscale connectivity
  @no_network_required ~w(init status auth daemon unlock lock config help version)

  def main(args) do
    # Start required OTP applications for :httpc
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    args
    |> parse_global_opts()
    |> maybe_check_network()
    |> dispatch()
    |> System.halt()
  end

  # ── Global option parsing ──────────────────────────────────────────────

  defp parse_global_opts(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [
          host: :string,
          port: :integer,
          token: :string,
          data_dir: :string,
          no_color: :boolean
        ],
        aliases: [h: :host, p: :port, t: :token, d: :data_dir]
      )

    config = %{
      host: Keyword.get(opts, :host, "127.0.0.1"),
      port: Keyword.get(opts, :port, 4884),
      token: Keyword.get(opts, :token),
      data_dir: Keyword.get(opts, :data_dir, default_data_dir()),
      no_color: Keyword.get(opts, :no_color, false)
    }

    Formatter.set_color(!config.no_color)

    {config, rest}
  end

  # ── Network connectivity guard ─────────────────────────────────────────

  defp maybe_check_network({config, args} = input) do
    command = List.first(args) || ""

    if command in @no_network_required do
      input
    else
      case check_network(config) do
        :ok -> input
        :daemon_down -> {:halt, :daemon_down}
        :network_down -> {:halt, :network_down}
      end
    end
  end

  defp check_network(config) do
    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"network" => %{"connected" => true}}}} ->
        :ok

      {200, {:ok, %{"network" => %{"connected" => false}}}} ->
        :network_down

      {:error, {:failed_connect, _}} ->
        :daemon_down

      _ ->
        # Can't determine — let the command proceed and fail naturally
        :ok
    end
  end

  # ── Command dispatch ───────────────────────────────────────────────────

  defp dispatch({:halt, :daemon_down}) do
    Formatter.daemon_unreachable()
    1
  end

  defp dispatch({:halt, :network_down}) do
    Formatter.error("Not connected to Tailscale")
    IO.puts("")
    IO.puts("  This command requires an active Tailscale connection.")
    IO.puts("  Run the following to authenticate:")
    IO.puts("")
    IO.puts("    \e[1mdustctl auth\e[0m")
    IO.puts("")
    1
  end

  defp dispatch({config, ["init" | args]}), do: Commands.Init.run(config, args)

  defp dispatch({config, ["status" | args]}), do: Commands.Status.run(config, args)

  defp dispatch({config, ["auth" | args]}), do: Commands.Network.run(config, args)

  defp dispatch({config, ["daemon" | args]}), do: Commands.Daemon.run(config, args)

  defp dispatch({config, ["unlock" | args]}), do: Commands.Auth.unlock(config, args)
  defp dispatch({config, ["lock" | args]}), do: Commands.Auth.lock(config, args)

  defp dispatch({config, ["ls" | args]}), do: Commands.Fs.ls(config, args)
  defp dispatch({config, ["mkdir" | args]}), do: Commands.Fs.mkdir(config, args)
  defp dispatch({config, ["upload" | args]}), do: Commands.Fs.upload(config, args)
  defp dispatch({config, ["download" | args]}), do: Commands.Fs.download(config, args)
  defp dispatch({config, ["rm" | args]}), do: Commands.Fs.rm(config, args)

  defp dispatch({config, ["nodes" | args]}), do: Commands.Cluster.nodes(config, args)
  defp dispatch({config, ["invite" | args]}), do: Commands.Cluster.invite(config, args)
  defp dispatch({config, ["join" | args]}), do: Commands.Cluster.join(config, args)

  defp dispatch({config, ["config" | args]}), do: Commands.Config.run(config, args)

  defp dispatch({config, ["gc" | args]}), do: Commands.Gc.run(config, args)

  defp dispatch({_config, ["version" | _]}) do
    IO.puts("dustctl #{@version}")
    0
  end

  defp dispatch({_config, ["help" | _]}), do: print_help()
  defp dispatch({_config, []}), do: print_help()

  defp dispatch({_config, [unknown | _]}) do
    Formatter.error("Unknown command: #{unknown}")
    Formatter.info("Run 'dustctl help' for usage information.")
    1
  end

  defp print_help do
    IO.puts(@moduledoc)
    0
  end

  defp default_data_dir do
    case :os.type() do
      {:win32, _} ->
        case System.get_env("LOCALAPPDATA") do
          nil -> Path.join(System.user_home!(), ".dust")
          appdata -> Path.join(appdata, "Dust")
        end

      _ ->
        case System.get_env("DUST_DATA_DIR") do
          nil -> Path.join(System.user_home!(), ".dust")
          dir -> dir
        end
    end
  end
end
