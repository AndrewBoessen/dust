defmodule Dust.Api.Service do
  @moduledoc """
  Cross-platform system service management for the Dust daemon.

  Detects the current OS and dispatches to the appropriate service manager:

    * **Linux** — systemd (`systemctl`)
    * **macOS** — launchd (`launchctl`)
    * **Windows** — WinSW wrapper

  ## Usage

      Dust.Api.Service.install()    # Copy template and enable service
      Dust.Api.Service.uninstall()  # Disable and remove service
      Dust.Api.Service.status()     # :running | :stopped | :not_installed
      Dust.Api.Service.start()      # Start the service
      Dust.Api.Service.stop()       # Stop the service
  """

  require Logger

  @service_templates_dir "rel/service"

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Installs the Dust daemon as a system service.

  Copies the appropriate service template to the OS-specific location
  and enables it for automatic startup.
  """
  @spec install() :: :ok | {:error, term()}
  def install do
    case :os.type() do
      {:unix, :linux} -> install_systemd()
      {:unix, :darwin} -> install_launchd()
      {:win32, _} -> install_winsw()
      other -> {:error, {:unsupported_os, other}}
    end
  end

  @doc """
  Uninstalls the Dust daemon system service.
  """
  @spec uninstall() :: :ok | {:error, term()}
  def uninstall do
    case :os.type() do
      {:unix, :linux} -> uninstall_systemd()
      {:unix, :darwin} -> uninstall_launchd()
      {:win32, _} -> uninstall_winsw()
      other -> {:error, {:unsupported_os, other}}
    end
  end

  @doc """
  Returns the current status of the system service.
  """
  @spec status() :: :running | :stopped | :not_installed | {:error, term()}
  def status do
    case :os.type() do
      {:unix, :linux} -> status_systemd()
      {:unix, :darwin} -> status_launchd()
      {:win32, _} -> status_winsw()
      other -> {:error, {:unsupported_os, other}}
    end
  end

  @doc """
  Starts the system service.
  """
  @spec start() :: :ok | {:error, term()}
  def start do
    case :os.type() do
      {:unix, :linux} -> run_cmd("systemctl", ["start", "dust"])
      {:unix, :darwin} -> run_cmd("launchctl", ["load", launchd_plist_dest()])
      {:win32, _} -> run_cmd("net", ["start", "dust"])
      other -> {:error, {:unsupported_os, other}}
    end
  end

  @doc """
  Stops the system service.
  """
  @spec stop() :: :ok | {:error, term()}
  def stop do
    case :os.type() do
      {:unix, :linux} -> run_cmd("systemctl", ["stop", "dust"])
      {:unix, :darwin} -> run_cmd("launchctl", ["unload", launchd_plist_dest()])
      {:win32, _} -> run_cmd("net", ["stop", "dust"])
      other -> {:error, {:unsupported_os, other}}
    end
  end

  # ── Linux (systemd) ────────────────────────────────────────────────────

  @systemd_unit_dest "/etc/systemd/system/dust.service"

  defp install_systemd do
    source = template_path("linux/dust.service")

    with :ok <- copy_file(source, @systemd_unit_dest),
         :ok <- run_cmd("systemctl", ["daemon-reload"]),
         :ok <- run_cmd("systemctl", ["enable", "dust"]) do
      Logger.info("Service: installed systemd unit at #{@systemd_unit_dest}")
      :ok
    end
  end

  defp uninstall_systemd do
    with :ok <- run_cmd("systemctl", ["stop", "dust"]),
         :ok <- run_cmd("systemctl", ["disable", "dust"]),
         :ok <- delete_file(@systemd_unit_dest),
         :ok <- run_cmd("systemctl", ["daemon-reload"]) do
      Logger.info("Service: removed systemd unit")
      :ok
    end
  end

  defp status_systemd do
    case System.cmd("systemctl", ["is-active", "dust"], stderr_to_stdout: true) do
      {"active\n", 0} -> :running
      {"inactive\n", _} -> :stopped
      _ ->
        if File.exists?(@systemd_unit_dest), do: :stopped, else: :not_installed
    end
  rescue
    _ -> :not_installed
  end

  # ── macOS (launchd) ────────────────────────────────────────────────────

  defp launchd_plist_dest do
    Path.join(System.user_home!(), "Library/LaunchAgents/com.dust.daemon.plist")
  end

  defp install_launchd do
    source = template_path("macos/com.dust.daemon.plist")
    dest = launchd_plist_dest()

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- copy_file(source, dest),
         :ok <- run_cmd("launchctl", ["load", dest]) do
      Logger.info("Service: installed launchd plist at #{dest}")
      :ok
    end
  end

  defp uninstall_launchd do
    dest = launchd_plist_dest()

    with :ok <- run_cmd("launchctl", ["unload", dest]),
         :ok <- delete_file(dest) do
      Logger.info("Service: removed launchd plist")
      :ok
    end
  end

  defp status_launchd do
    dest = launchd_plist_dest()

    if File.exists?(dest) do
      case System.cmd("launchctl", ["list"], stderr_to_stdout: true) do
        {output, 0} ->
          if String.contains?(output, "com.dust.daemon"), do: :running, else: :stopped

        _ ->
          :stopped
      end
    else
      :not_installed
    end
  rescue
    _ -> :not_installed
  end

  # ── Windows (WinSW) ────────────────────────────────────────────────────

  defp install_winsw do
    source = template_path("windows/dust-service.xml")
    install_dir = winsw_install_dir()

    with :ok <- File.mkdir_p(install_dir),
         dest <- Path.join(install_dir, "dust-service.xml"),
         :ok <- copy_file(source, dest),
         :ok <- run_cmd(Path.join(install_dir, "dust-service.exe"), ["install"]) do
      Logger.info("Service: installed WinSW service")
      :ok
    end
  end

  defp uninstall_winsw do
    install_dir = winsw_install_dir()

    with :ok <- run_cmd(Path.join(install_dir, "dust-service.exe"), ["uninstall"]) do
      Logger.info("Service: removed WinSW service")
      :ok
    end
  end

  defp status_winsw do
    install_dir = winsw_install_dir()
    exe = Path.join(install_dir, "dust-service.exe")

    if File.exists?(exe) do
      case System.cmd(exe, ["status"], stderr_to_stdout: true) do
        {output, 0} ->
          cond do
            String.contains?(output, "Started") -> :running
            String.contains?(output, "Stopped") -> :stopped
            true -> :stopped
          end

        _ ->
          :not_installed
      end
    else
      :not_installed
    end
  rescue
    _ -> :not_installed
  end

  defp winsw_install_dir do
    case System.get_env("LOCALAPPDATA") do
      nil -> "C:\\ProgramData\\Dust"
      appdata -> Path.join(appdata, "Dust")
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp template_path(relative) do
    # In a release, templates are bundled under priv/
    priv_path = :code.priv_dir(:dust_api) |> to_string()
    release_path = Path.join([priv_path, "service", relative])

    if File.exists?(release_path) do
      release_path
    else
      # Development: read from the project tree
      Path.join([File.cwd!(), @service_templates_dir, relative])
    end
  end

  defp copy_file(source, dest) do
    case File.cp(source, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, {:copy_failed, source, dest, reason}}
    end
  end

  defp delete_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:delete_failed, path, reason}}
    end
  end

  defp run_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:command_failed, cmd, args, code, output}}
    end
  rescue
    e -> {:error, {:command_error, cmd, Exception.message(e)}}
  end
end
