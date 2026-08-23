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
      mv SOURCE DEST        Move or rename a file or directory
      rm ID                 Remove a file or directory
      stat PATH             Show metadata for a file

      nodes                 List cluster peers
      invite                Create an invite token
      join IP TOKEN         Join an existing cluster

      config                Show current configuration
      config set KEY VALUE  Update a runtime configuration value

      gc stats              Show garbage collection statistics
      gc sweep              Trigger a manual GC sweep

      ui open               Open the web UI in your browser
      ui status             Show the web UI URL and reachability

      help                  Show this help message
      version               Show version

  `help` and `version` (also `--help` / `--version`, or `dustctl` with no
  arguments) work without a running daemon or a configured node.

  ## Global Options

      --host HOST           Daemon host (default: 127.0.0.1)
      --port PORT           Daemon port (default: 4884)
      --token TOKEN         API bearer token (default: read from data dir)
      --data-dir DIR        Data directory (default: ~/.dust)
  """

  alias Dust.CLI.{Client, Formatter, Commands}

  @version "0.2.5"

  # Commands that DO NOT require Tailscale connectivity
  @no_network_required ~w(init status auth daemon unlock lock config help version ui)

  # Flags that mean "help" / "version" rather than naming a command.
  # `-h` is deliberately absent: it is the alias for `--host`.
  @help_flags ~w(--help -?)
  @version_flags ~w(--version)

  @doc false
  def run(args) do
    {opts, command} =
      args
      |> normalize_offline_flags()
      |> parse_argv()

    run_command(opts, command)
  end

  # `help` and `version` have to work before the node is usable: with no
  # daemon running, before `dustctl init`, and before Tailscale is
  # authenticated. They are answered here, after the pure argv parse but
  # before build_config/1 (which asks the daemon for its data dir) and
  # before the Tailscale guard — so neither can keep the user from
  # reading the usage text.
  defp run_command(_opts, ["help" | _]), do: print_help()
  defp run_command(_opts, ["version" | _]), do: print_version()
  defp run_command(_opts, []), do: print_help()

  defp run_command(opts, command) do
    {build_config(opts), command}
    |> maybe_check_network()
    |> dispatch()
  end

  # `dustctl` with no arguments is a request for help, as is `--help`
  # anywhere in the line. OptionParser's `strict:` list discards those
  # flags as unknown, which used to leave an empty command that fell
  # through to the connectivity guard instead of printing usage.
  defp normalize_offline_flags(args) do
    cond do
      Enum.any?(args, &(&1 in @help_flags)) -> ["help"]
      Enum.any?(args, &(&1 in @version_flags)) -> ["version"]
      true -> args
    end
  end

  # ── Global option parsing ──────────────────────────────────────────────

  @global_switches [host: :string, port: :integer, token: :string, data_dir: :string]
  @global_aliases [h: :host, p: :port, t: :token, d: :data_dir]

  # Pure: splits global flags from the command without touching the daemon.
  #
  # Uses parse_head/2 so parsing stops at the command word and everything
  # after it reaches the command untouched. Plain parse/2 pulls switches
  # out of the whole line and *drops* the ones it doesn't know, which
  # silently swallowed every sub-command flag (`dustctl join IP TOK
  # --force`, `dustctl unlock --password ...`) before it could be read.
  #
  # Global flags written after the command are still honoured — they are
  # scanned out of the tail and merged, with anything before the command
  # winning — so `dustctl status --port 4899` keeps working.
  defp parse_argv(args) do
    {head_opts, rest, _} =
      OptionParser.parse_head(args, strict: @global_switches, aliases: @global_aliases)

    {tail_opts, _rest, _invalid} =
      OptionParser.parse(rest, strict: @global_switches, aliases: @global_aliases)

    {Keyword.merge(tail_opts, head_opts), rest}
  end

  defp build_config(opts) do
    explicit_data_dir = Keyword.get(opts, :data_dir)

    config = %{
      host: Keyword.get(opts, :host, "127.0.0.1"),
      port: Keyword.get(opts, :port, 4884),
      token: Keyword.get(opts, :token),
      data_dir: explicit_data_dir || default_data_dir()
    }

    # If --data-dir was not explicitly set, ask the running daemon for its
    # actual persist_dir. /api/v1/status is auth-exempt so no token needed.
    if explicit_data_dir do
      config
    else
      resolve_data_dir_from_daemon(config)
    end
  end

  defp resolve_data_dir_from_daemon(config) do
    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"persist_dir" => dir}}} when is_binary(dir) and dir != "" ->
        %{config | data_dir: dir}

      _ ->
        config
    end
  rescue
    _ -> config
  end

  # ── Network connectivity guard ─────────────────────────────────────────

  defp maybe_check_network({config, args} = input) do
    # run_command/2 already answered the empty command; treating it as
    # help here too keeps a stray empty list off the connectivity check.
    command = List.first(args) || "help"

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
    Formatter.info_box("Tip", [
      "This command requires an active Tailscale connection.\n\n",
      Owl.Data.tag("  dustctl auth", :bright)
    ])
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
  defp dispatch({config, ["mv" | args]}), do: Commands.Fs.mv(config, args)
  defp dispatch({config, ["rm" | args]}), do: Commands.Fs.rm(config, args)
  defp dispatch({config, ["stat" | args]}), do: Commands.Fs.stat(config, args)

  defp dispatch({config, ["nodes" | args]}), do: Commands.Cluster.nodes(config, args)
  defp dispatch({config, ["invite" | args]}), do: Commands.Cluster.invite(config, args)
  defp dispatch({config, ["join" | args]}), do: Commands.Cluster.join(config, args)

  defp dispatch({config, ["config" | args]}), do: Commands.Config.run(config, args)

  defp dispatch({config, ["gc" | args]}), do: Commands.Gc.run(config, args)

  defp dispatch({config, ["ui" | args]}), do: Commands.Ui.run(config, args)

  # Unreachable via run_command/2, which answers the empty command first.
  # Kept so dispatch/1 stays total over its input and can never raise a
  # FunctionClauseError on an empty list.
  defp dispatch({_config, []}), do: print_help()

  defp dispatch({_config, [unknown | _]}) do
    Formatter.error("Unknown command: #{unknown}")
    Formatter.info("Run 'dustctl help' for usage information.")
    1
  end

  defp print_version do
    IO.puts("dustctl #{@version}")
    0
  end

  defp print_help do
    groups = [
      {"Setup", [
        {"init", "First-time setup wizard"},
        {"status", "Show node status"}
      ]},
      {"Network", [
        {"auth", "Check Tailscale status, show auth URL if needed"},
        {"auth status", "Detailed network connectivity info"},
        {"auth logout", "Disconnect from Tailscale"}
      ]},
      {"Daemon", [
        {"daemon start", "Start the daemon"},
        {"daemon stop", "Stop the daemon"},
        {"daemon status", "Check if daemon is running"},
        {"daemon install", "Install as system service"},
        {"daemon uninstall", "Remove system service"}
      ]},
      {"Key Store", [
        {"unlock", "Unlock the key store"},
        {"lock", "Lock the key store"}
      ]},
      {"File System", [
        {"ls [PATH]", "List directory contents"},
        {"mkdir PATH", "Create a directory"},
        {"upload FILE [REMOTE]", "Upload a file"},
        {"download PATH DEST", "Download a file to a local path"},
        {"mv SOURCE DEST", "Move or rename a file or directory"},
        {"rm PATH", "Remove a file or directory"},
        {"stat PATH", "Show metadata for a file"}
      ]},
      {"Cluster", [
        {"nodes", "List cluster peers"},
        {"invite", "Create an invite token"},
        {"join IP TOKEN", "Join an existing cluster"}
      ]},
      {"Config", [
        {"config", "Show current configuration"},
        {"config set KEY VALUE", "Update a runtime configuration value"}
      ]},
      {"Garbage Collection", [
        {"gc stats", "Show garbage collection statistics"},
        {"gc sweep", "Trigger a manual GC sweep"}
      ]},
      {"Web UI", [
        {"ui open", "Open the web UI in your browser"},
        {"ui status", "Show the web UI URL and reachability"}
      ]},
      {"Other", [
        {"help", "Show this help message"},
        {"version", "Show version"}
      ]}
    ]

    options = [
      {"--host HOST", "Daemon host (default: 127.0.0.1)"},
      {"--port PORT", "Daemon port (default: 4884)"},
      {"--token TOKEN", "API bearer token (default: read from data dir)"},
      {"--data-dir DIR", "Data directory (default: ~/.dust)"}
    ]

    all_items =
      Enum.flat_map(groups, fn {_, cmds} -> cmds end) ++ options

    col_width =
      all_items
      |> Enum.map(fn {name, _} -> String.length(name) end)
      |> Enum.max()
      |> Kernel.+(4)

    IO.puts("dustctl #{@version} - Distributed file system CLI")
    IO.puts("")
    IO.puts("Usage: dustctl [global options] <command> [arguments]")
    IO.puts("")
    IO.puts("Commands:")

    Enum.each(groups, fn {group_name, commands} ->
      IO.puts("")
      IO.puts("  #{group_name}:")

      Enum.each(commands, fn {cmd, desc} ->
        IO.puts("    #{String.pad_trailing(cmd, col_width)}#{desc}")
      end)
    end)

    IO.puts("")
    IO.puts("Global Options:")
    IO.puts("")

    Enum.each(options, fn {opt, desc} ->
      IO.puts("  #{String.pad_trailing(opt, col_width + 2)}#{desc}")
    end)

    IO.puts("")
    IO.puts("Run 'dustctl help' to show this message.")
    IO.puts("")
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
        Path.join(System.user_home!(), ".dust")
    end
  end
end
