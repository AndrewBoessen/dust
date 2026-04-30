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

    with {:ok, template} <- File.read(source),
         {:ok, current_user} <- current_os_user(),
         {:ok, home_dir} <- current_home_dir(),
         content = inject_service_user(template, current_user, home_dir),
         :ok <- write_service_file(content),
         :ok <- run_cmd("sudo", ["systemctl", "daemon-reload"]),
         :ok <- run_cmd("sudo", ["systemctl", "enable", "dust"]) do
      Logger.info("Service: installed systemd unit at #{@systemd_unit_dest} (User=#{current_user}, HOME=#{home_dir})")
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_os_user do
    case System.get_env("USER") do
      nil ->
        case System.cmd("whoami", [], stderr_to_stdout: true) do
          {name, 0} -> {:ok, String.trim(name)}
          _ -> {:error, :cannot_determine_user}
        end

      user ->
        {:ok, user}
    end
  end

  defp current_home_dir do
    case System.user_home() do
      nil -> {:error, :cannot_determine_home}
      home -> {:ok, home}
    end
  end

  defp inject_service_user(template, user, home_dir) do
    template
    |> then(fn t ->
      if String.contains?(t, "\nUser=") do
        Regex.replace(~r/\nUser=[^\n]*/, t, "\nUser=#{user}")
      else
        String.replace(t, "\n[Service]", "\n[Service]\nUser=#{user}")
      end
    end)
    |> then(fn t ->
      if String.contains?(t, "\nEnvironment=HOME=") do
        Regex.replace(~r/\nEnvironment=HOME=[^\n]*/, t, "\nEnvironment=HOME=#{home_dir}")
      else
        String.replace(t, "\n[Service]", "\n[Service]\nEnvironment=HOME=#{home_dir}")
      end
    end)
  end

  defp write_service_file(content) do
    tmp = System.tmp_dir!() |> Path.join("dust.service.tmp")

    with :ok <- File.write(tmp, content),
         :ok <- run_cmd("sudo", ["cp", tmp, @systemd_unit_dest]),
         :ok <- run_cmd("sudo", ["chmod", "644", @systemd_unit_dest]) do
      File.rm(tmp)
      :ok
    end
  end

  defp uninstall_systemd do
    with :ok <- run_cmd("sudo", ["systemctl", "stop", "dust"]),
         :ok <- run_cmd("sudo", ["systemctl", "disable", "dust"]),
         :ok <- run_cmd("sudo", ["rm", "-f", @systemd_unit_dest]),
         :ok <- run_cmd("sudo", ["systemctl", "daemon-reload"]) do
      Logger.info("Service: removed systemd unit")
      :ok
    end
  end

  defp status_systemd do
    case System.cmd("systemctl", ["is-active", "dust"], stderr_to_stdout: true) do
      {"active\n", 0} ->
        :running

      {"inactive\n", _} ->
        :stopped

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
    home_dir = System.user_home!()
    log_dir = Path.join(home_dir, "Library/Logs/dust")

    with {:ok, template} <- File.read(source),
         content = inject_launchd_paths(template, home_dir, log_dir),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- File.mkdir_p(log_dir),
         :ok <- File.write(dest, content),
         :ok <- run_cmd("launchctl", ["load", dest]) do
      Logger.info("Service: installed launchd plist at #{dest}")
      :ok
    end
  end

  defp inject_launchd_paths(template, home_dir, log_dir) do
    template
    |> String.replace("/usr/local/var/log/dust/stdout.log", Path.join(log_dir, "stdout.log"))
    |> String.replace("/usr/local/var/log/dust/stderr.log", Path.join(log_dir, "stderr.log"))
    |> String.replace(
      "<key>EnvironmentVariables</key>\n    <dict>",
      "<key>EnvironmentVariables</key>\n    <dict>\n        <key>HOME</key>\n        <string>#{home_dir}</string>"
    )
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
    priv_path = :code.priv_dir(:dust_api) |> to_string()
    Path.join([priv_path, "service", relative])
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
