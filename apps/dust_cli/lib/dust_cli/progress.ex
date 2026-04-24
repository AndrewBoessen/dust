defmodule Dust.CLI.Progress do
  @moduledoc false

  use WebSockex

  @type_to_event %{upload: "upload_progress", download: "download_progress"}

  def start(config, label, type) do
    with {:ok, token} <- resolve_token(config) do
      url = "ws://#{config.host}:#{config.port}/api/v1/ws/events"

      WebSockex.start_link(url, __MODULE__, %{
        label: label,
        event_type: @type_to_event[type],
        total: nil,
        current: 0,
        caller: self()
      }, extra_headers: [{"Authorization", "Bearer #{token}"}])
    end
  end

  def stop(pid) when is_pid(pid) do
    receive do
      :transfer_complete -> :ok
    after
      200 -> :ok
    end
    Owl.LiveScreen.await_render()
    Process.exit(pid, :normal)
  end

  def stop(_), do: :ok

  @impl true
  def handle_frame({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, %{"type" => t, "chunk" => chunk, "total" => total}}
      when t == state.event_type ->
        if is_nil(state.total) do
          Owl.ProgressBar.start(id: :transfer, label: state.label, total: total)
        end

        step = chunk - state.current

        if step > 0 do
          Owl.ProgressBar.inc(id: :transfer, step: step)
        end

        if chunk >= total do
          send(state.caller, :transfer_complete)
        end

        {:ok, %{state | total: total, current: chunk}}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_disconnect(_conn_status, state), do: {:ok, state}

  # ── Private ────────────────────────────────────────────────────────────

  defp resolve_token(%{token: token}) when is_binary(token) and token != "", do: {:ok, token}

  defp resolve_token(%{data_dir: data_dir}) do
    path = Path.join(data_dir, "api_token")

    case File.read(path) do
      {:ok, token} -> {:ok, String.trim(token)}
      error -> error
    end
  end
end
