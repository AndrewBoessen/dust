defmodule Bridge do
  @moduledoc """
  Elixir interface to the Go tsnet sidecar.

  Communicates with the Go process over an Erlang port using `{:packet, 4}`
  framing. Each command is a UTF-8 string sent as a length-prefixed message;
  the sidecar responds with a length-prefixed reply.
  """

  use GenServer

  @behaviour Bridge.Behaviour

  require Logger

  @sidecar_path "native/tsnet_sidecar/tsnet_sidecar"

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a raw command string to the Go sidecar and return the response.
  """
  @spec send_command(String.t(), timeout()) :: {:ok, binary()} | {:error, term()}
  def send_command(command, timeout \\ 10_000) do
    GenServer.call(__MODULE__, {:send_command, command}, timeout)
  end

  @doc """
  Request the master key from a peer node over Tailscale.

  Returns `{:ok, <<key::binary-32>>}` on success.
  """
  @impl true
  @spec request_key(String.t()) :: {:ok, binary()} | {:error, term()}
  def request_key(peer_address) do
    case send_command("KEY_REQUEST #{peer_address}", 30_000) do
      {:ok, <<"OK:", key::binary-32>>} ->
        {:ok, key}

      {:ok, <<"ERR: ", reason::binary>>} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      error ->
        error
    end
  end

  @doc """
  Tell the Go sidecar to start serving the master key to peers.

  The key is sent as raw bytes in the command payload.
  """
  @impl true
  @spec serve_key(binary()) :: :ok | {:error, term()}
  def serve_key(key) when byte_size(key) == 32 do
    case send_command("KEY_SERVE " <> key) do
      {:ok, <<"OK:", _::binary>>} -> :ok
      {:ok, <<"ERR: ", reason::binary>>} -> {:error, reason}
      error -> error
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(opts) do
    sidecar = Keyword.get(opts, :sidecar_path, sidecar_path())

    port =
      Port.open({:spawn_executable, sidecar}, [
        :binary,
        :exit_status,
        {:packet, 4}
      ])

    {:ok, %{port: port}}
  end

  @impl true
  def handle_call({:send_command, command}, _from, %{port: port} = state) do
    Port.command(port, command)

    receive do
      {^port, {:data, response}} ->
        {:reply, {:ok, response}, state}

      {^port, {:exit_status, code}} ->
        {:reply, {:error, {:sidecar_exited, code}}, state}
    after
      30_000 ->
        {:reply, {:error, :timeout}, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("Bridge: Go sidecar exited with code #{code}")
    {:stop, {:sidecar_exited, code}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────

  defp sidecar_path do
    Application.get_env(:bridge, :sidecar_path, @sidecar_path)
  end
end
