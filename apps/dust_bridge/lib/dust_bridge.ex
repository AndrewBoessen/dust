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
  Lazily spawns the Go `tsnet_sidecar` if the bridge was started in
  deferred mode.

  Deferred mode is used during first-time setup: the bridge boots
  without touching Tailscale so it doesn't register a hostname using
  the placeholder `node_name` (`"dust"`). The init flow (CLI `dustctl
  init` or the Web UI `SetupLive`) calls this after the user has chosen
  their device name so the sidecar's Tailscale identity is correct on
  its very first connection.

  Returns `:ok` if the sidecar is now running (or was already running).
  """
  @spec start_sidecar() :: :ok | {:error, term()}
  def start_sidecar do
    GenServer.call(__MODULE__, :start_sidecar)
  end

  @doc "True if the sidecar Port is open and accepting commands."
  @spec sidecar_running?() :: boolean()
  def sidecar_running? do
    GenServer.call(__MODULE__, :sidecar_running?)
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
  Tell the Go sidecar to stop serving secrets to joining peers.

  Closes the key-exchange listener on port 9473, wipes the cached master key
  and OTP cookie, and revokes any outstanding invite tokens. Called by
  `Dust.Core.KeyStore.lock/0` so that a locked node cannot leak the master
  key over Tailscale.
  """
  @impl true
  @spec stop_serving_secrets() :: :ok | {:error, term()}
  def stop_serving_secrets do
    case send_command("STOP_SECRETS") do
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
  Returns the names of all peer dust nodes visible to the sidecar.

  Each entry is the peer's chosen node name (recovered from its Tailscale
  hostname). Callers route to a peer by translating the name into a node
  atom (`:"dust@<name>"`) — the EPMD module uses `resolve_peer/1` to turn
  the name into a routable Tailscale IP at connection time.
  """
  @impl true
  @spec get_peers() :: {:ok, [String.t()]} | {:error, term()}
  def get_peers() do
    case send_command("PEERS") do
      {:ok, <<"OK:", names::binary>>} ->
        {:ok, String.split(names, ",", trim: true)}

      {:ok, <<"ERR: ", reason::binary>>} ->
        {:error, reason}

      error ->
        error
    end
  end

  @doc """
  Resolves a peer's chosen node name to its current Tailscale IP.

  Looks up the peer whose Tailscale hostname is `dust-node-<name>` and
  returns its first Tailscale IP. Used by `Dust.Bridge.EPMD` to turn a
  node atom like `:"dust@alice"` into a proxy target.
  """
  @impl true
  @spec resolve_peer(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_peer(name) when is_binary(name) do
    case send_command("RESOLVE " <> name) do
      {:ok, <<"OK:", ip::binary>>} -> {:ok, String.trim(ip)}
      {:ok, <<"ERR: ", reason::binary>>} -> {:error, reason}
      error -> error
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

  @doc """
  Queries the Go sidecar for the current Tailscale authentication state.

  Returns a map with:
    - `:state` — `"authenticated"`, `"needs_login"`, or `"connecting"`
    - `:self_ip` — the node's Tailscale IP (empty string if not yet assigned)
    - `:auth_url` — the login URL to visit (empty string if not needed)
  """
  @impl true
  @spec auth_status() ::
          {:ok, %{state: String.t(), self_ip: String.t(), auth_url: String.t()}}
          | {:error, term()}
  def auth_status do
    case send_command("AUTH_STATUS") do
      {:ok, <<"OK:", payload::binary>>} ->
        case String.split(payload, "|", parts: 3) do
          [state, self_ip, auth_url] ->
            {:ok, %{state: state, self_ip: self_ip, auth_url: auth_url}}

          _ ->
            {:error, {:bad_response, payload}}
        end

      {:ok, <<"ERR: ", reason::binary>>} ->
        {:error, reason}

      error ->
        error
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(opts) do
    state = %{port: nil, opts: opts}

    if first_time_setup?() do
      # No keystore yet: defer sidecar startup so Tailscale doesn't get
      # registered under the placeholder node_name ("dust"). The init
      # flow will call `start_sidecar/0` after the user picks a name.
      Logger.info("Bridge: deferred sidecar startup — waiting for first-time init to complete")
      {:ok, state}
    else
      {:ok, open_sidecar_port(state)}
    end
  end

  @impl true
  def handle_call(:start_sidecar, _from, %{port: nil} = state) do
    Logger.info("Bridge: opening sidecar port after first-time init")
    new_state = open_sidecar_port(state)

    # Re-trigger the one-shot port-exposure setup now that the sidecar
    # is up; the Bridge.Setup task may have already run and failed.
    _ = Task.start(fn -> Process.sleep(1_000); Dust.Bridge.Setup.run() end)

    {:reply, :ok, new_state}
  end

  def handle_call(:start_sidecar, _from, state),
    do: {:reply, :ok, state}

  def handle_call(:sidecar_running?, _from, %{port: port} = state),
    do: {:reply, is_port(port), state}

  def handle_call({:send_command, _command}, _from, %{port: nil} = state) do
    {:reply, {:error, :sidecar_deferred}, state}
  end

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
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) when is_port(port) do
    Logger.error("Bridge: Go sidecar exited with code #{code}")
    {:stop, {:sidecar_exited, code}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────

  defp open_sidecar_port(state) do
    opts = Map.get(state, :opts, [])
    sidecar = Keyword.get(opts, :sidecar_path, sidecar_path())
    state_dir = Keyword.get(opts, :ts_state_dir, Dust.Utilities.File.ts_state_dir())

    # Read node_name at port-open time — for deferred starts this happens
    # after the user has picked their device name during init.
    hostname =
      System.get_env("TS_HOSTNAME") || "dust-node-#{Dust.Utilities.Config.node_name()}"

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

    %{state | port: port}
  end

  defp first_time_setup? do
    not File.exists?(Dust.Utilities.File.master_key_file())
  end

  @spec sidecar_path() :: Path.t()
  defp sidecar_path do
    binary_name =
      case :os.type() do
        {:win32, _} -> "tsnet_sidecar.exe"
        _ -> "tsnet_sidecar"
      end

    default_path = Path.join(to_string(:code.priv_dir(:dust_bridge)), binary_name)
    Application.get_env(:dust_bridge, :sidecar_path, default_path)
  end
end
