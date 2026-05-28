defmodule Dust.CLI.Commands.Ui do
  @moduledoc false

  alias Dust.CLI.{Client, Formatter}

  def run(config, []), do: open(config, [])
  def run(config, ["open" | args]), do: open(config, args)
  def run(config, ["status" | args]), do: status(config, args)

  def run(_config, [unknown | _]) do
    Formatter.error("Unknown ui subcommand: #{unknown}")
    Formatter.info("Available: open, status")
    1
  end

  defp open(config, _args) do
    case ui_url(config) do
      {:ok, url} ->
        case launch_browser(url) do
          :ok ->
            Formatter.success("Opened #{url}")
            0

          {:error, reason} ->
            Formatter.warning("Could not open browser: #{reason}")
            Formatter.info(url)
            0
        end

      {:error, reason} ->
        Formatter.error(reason)
        1
    end
  end

  defp status(config, _args) do
    case ui_url(config) do
      {:ok, url} ->
        Formatter.kv([{"URL", url}, {"Reachable", reachability(url)}])
        0

      {:error, reason} ->
        Formatter.error(reason)
        1
    end
  end

  # ── URL resolution ───────────────────────────────────────────────────

  defp ui_url(config) do
    case Client.get(config, "/api/v1/status") do
      {200, {:ok, body}} ->
        port = Map.get(body, "ui_port") || 4885
        bind = Map.get(body, "ui_bind") || "127.0.0.1"
        host = display_host(bind)
        {:ok, "http://#{host}:#{port}"}

      {:error, {:failed_connect, _}} ->
        {:error, "Daemon is unreachable. Start it with `dustctl daemon start`."}

      other ->
        {:error, "Could not query daemon status: #{inspect(other)}"}
    end
  end

  # Browsers don't accept "0.0.0.0" — substitute with localhost.
  defp display_host("0.0.0.0"), do: "127.0.0.1"
  defp display_host(""), do: "127.0.0.1"
  defp display_host(bind), do: bind

  # ── Browser launching ────────────────────────────────────────────────

  defp launch_browser(url) do
    {cmd, args} = browser_open_command(url)

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "#{cmd} exited #{status}: #{String.trim(out)}"}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  defp browser_open_command(url) do
    case :os.type() do
      {:unix, :darwin} -> {"open", [url]}
      {:win32, _} -> {"cmd", ["/c", "start", "", url]}
      {:unix, _} -> {"xdg-open", [url]}
    end
  end

  # ── Reachability check ───────────────────────────────────────────────

  defp reachability(url) do
    request = {String.to_charlist(url), []}

    case :httpc.request(:head, request, [timeout: 1000, connect_timeout: 500], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..399 -> "yes (HTTP #{status})"
      {:ok, {{_, status, _}, _, _}} -> "responded HTTP #{status}"
      {:error, reason} -> "no (#{inspect(reason)})"
    end
  rescue
    _ -> "no"
  end
end
