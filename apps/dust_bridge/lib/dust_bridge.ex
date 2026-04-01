defmodule Dust.Bridge do
  @moduledoc """
  GenServer that drives the Go `tsnet_sidecar` process via an Erlang port.

  The sidecar manages a Tailscale `tsnet` network interface and exposes a
  simple text protocol over `{:packet, 4}` (length-prefixed) framing.
  Commands are plain UTF-8 strings (e.g. `"PEERS"`, `"PROXY 100.64.0.2:9000"`)
  and responses are prefixed with `"OK:"` or `"ERR: "`.

  This module implements `Dust.Bridge.Behaviour` so consumers can swap in
  a mock for testing via `:bridge_module` application config.
  """

  use GenServer

  @behaviour Dust.Bridge.Behaviour

  require Logger

  # ── Public API ──────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sends a command string to the Go sidecar and returns the raw response.

  Most callers should use the higher-level functions (`join/2`, `get_peers/0`,
  etc.) instead of calling this directly. This function is public to support
  ad-hoc debugging and future protocol extensions.
  """
  @spec send_command(String.t(), timeout()) :: {:ok, binary()} | {:error, term()}
  def send_command(command, timeout \\ 10_000) do
    GenServer.call(__MODULE__, {:send_command, command}, timeout)
  end

  @doc """
  Request the master key and OTP cookie from a peer node over Tailscale using a token.

  This command dials a peer node's sidecar (on port 9473) using Tailscale's `tsnet`.
  The connection is secured by Tailscale, and the token is sent to authorize the transfer.
  If the token is valid (matches a generated invite token and hasn't expired), the peer
  responds with the encoded master key and OTP cookie.

  Returns `{:ok, master_key_b64, otp_cookie}` on success.
  """
  @impl true
  @spec join(String.t(), String.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def join(peer_address, token) do
    case send_command("JOIN #{peer_address} #{token}", 30_000) do
      {:ok, <<"OK:", secrets::binary>>} ->
        [master_key, otp_cookie] = String.split(secrets, ":", parts: 2)
        {:ok, master_key, otp_cookie}

      {:ok, <<"ERR: ", reason::binary>>} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      error ->
        error
    end
  end

  @doc """
  Tell the Go sidecar to start serving the master key and OTP cookie to peers.

  The sidecar will start listening for TCP connections on port 9473. Incoming connections
  are verified using Tailscale's `WhoIs` to ensure the peer has an authenticated
  Tailscale identity. The sidecar then expects a 32-byte token, which must match an active,
  unexpired invite token. Upon successful validation, the secrets are sent and the token is consumed.
  """
  @impl true
  @spec serve_secrets(String.t(), String.t()) :: :ok | {:error, term()}
  def serve_secrets(master_key_b64, otp_cookie) do
    case send_command("SERVE_SECRETS #{master_key_b64}:#{otp_cookie}") do
      {:ok, <<"OK:", _::binary>>} -> :ok
      {:ok, <<"ERR: ", reason::binary>>} -> {:error, reason}
      error -> error
    end
  end

  @doc """
  Generates a one-time secure token and registers it with the sidecar.

  The token is registered internally in the sidecar's invite map with a
  default time-to-live (TTL, e.g., 10 minutes) before it expires.
  It can only be used once by a joining peer to retrieve the network secrets.
  """
  @impl true
  @spec create_invite() :: {:ok, String.t()} | {:error, term()}
  def create_invite() do
    token = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    case send_command("INVITE_CREATE #{token}") do
      {:ok, <<"OK:", _::binary>>} -> {:ok, token}
      {:ok, <<"ERR: ", reason::binary>>} -> {:error, reason}
      error -> error
    end
  end

  @doc """
  Gets all peer Tailscale IPs from the tsnet sidecar.
  """
  @impl true
  @spec get_peers() :: {:ok, [String.t()]} | {:error, term()}
  def get_peers() do
    case send_command("PEERS") do
      {:ok, <<"OK:", ips::binary>>} ->
        ips_list = String.split(ips, ",", trim: true)
        {:ok, ips_list}

      {:ok, <<"ERR: ", reason::binary>>} ->
        {:error, reason}

      error ->
        error
    end
  end

  @doc """
  Asks the go sidecar to proxy a connection to a target over Tailscale.
  Returns the local port listening for the proxied connection.
  """
  @impl true
  @spec proxy(String.t(), integer()) :: {:ok, integer()} | {:error, term()}
  def proxy(target_ip, target_port) do
    case send_command("PROXY #{target_ip}:#{target_port}") do
      {:ok, <<"OK:", local_port_str::binary>>} ->
        {port, _} = Integer.parse(local_port_str)
        {:ok, port}

      {:ok, <<"ERR: ", reason::binary>>} ->
        {:error, reason}

      error ->
        error
    end
  end

  @doc """
  Asks the go sidecar to expose a local port on the `tsnet` Tailscale IP.
  """
  @impl true
  @spec expose(integer()) :: :ok | {:error, term()}
  def expose(port) do
    case send_command("EXPOSE #{port}") do
      {:ok, <<"OK:", _::binary>>} -> :ok
      {:ok, <<"ERR: ", reason::binary>>} -> {:error, reason}
      error -> error
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, %{port: port()}}
  def init(opts) do
    sidecar = Keyword.get(opts, :sidecar_path, sidecar_path())
    state_dir = Keyword.get(opts, :ts_state_dir, Dust.Utilities.File.ts_state_dir())

    node_prefix =
      Node.self()
      |> to_string()
      |> String.split("@")
      |> List.first() || "unknown"

    hostname = System.get_env("TS_HOSTNAME") || "dust-node-#{node_prefix}"

    ts_tags =
      Keyword.get(
        opts,
        :ts_tags,
        Application.get_env(:dust_bridge, :ts_tags, "tag:dust-node")
      )

    port =
      Port.open({:spawn_executable, sidecar}, [
        :binary,
        :exit_status,
        {:packet, 4},
        env: [
          {~c"TS_HOSTNAME", to_charlist(hostname)},
          {~c"TS_STATE_DIR", to_charlist(state_dir)},
          {~c"TS_TAGS", to_charlist(ts_tags)}
        ]
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

  @spec sidecar_path() :: Path.t()
  defp sidecar_path do
    default_path = Path.expand("../native/tsnet_sidecar/tsnet_sidecar", __DIR__)

    Application.get_env(:dust_bridge, :sidecar_path, default_path)
  end
end
