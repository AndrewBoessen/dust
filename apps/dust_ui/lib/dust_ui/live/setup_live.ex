defmodule Dust.Ui.SetupLive do
  @moduledoc """
  First-time setup wizard.

  Mirrors `dustctl init`: pick a device name, set a keystore password,
  bring up Tailscale with the chosen name (NOT before — the bridge
  defers its sidecar startup until init completes), then create a new
  network or join an existing one.

  Visited only when `Dust.Utilities.File.master_key_file/0` does not yet
  exist; `SessionController.new` redirects here. After a successful
  submission the LiveView mints a short-lived `Phoenix.Token` and
  navigates to `GET /setup/complete?t=...`, which actually sets the
  session cookie (LiveView sockets can't write to `Plug.Session`).
  """
  use Dust.Ui, :live_view

  @node_name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,62}\z/

  @impl true
  def mount(_params, _session, socket) do
    if first_time_setup?() do
      {:ok,
       assign(socket,
         page_title: "First-time setup",
         step: :choose,
         mode: nil,
         password: "",
         password_confirm: "",
         node_name: "dust",
         peer_ip: "",
         token: "",
         error: nil,
         busy?: false,
         confirm_key_overwrite: nil,
         tailscale: %{state: "unavailable", self_ip: nil, auth_url: nil}
       )}
    else
      {:ok, redirect(socket, to: ~p"/login")}
    end
  end

  defp first_time_setup?,
    do: not File.exists?(Dust.Utilities.File.master_key_file())

  # ── Step 1: Choose Create vs Join ───────────────────────────────────

  @impl true
  def handle_event("choose_mode", %{"mode" => mode}, socket) when mode in ["create", "join"] do
    {:noreply, assign(socket, mode: String.to_atom(mode), step: :details, error: nil)}
  end

  def handle_event("confirm_key_overwrite", _params, socket) do
    socket
    |> assign(busy?: true, confirm_key_overwrite: nil, error: nil)
    |> finish_join(true)
  end

  def handle_event("cancel_key_overwrite", _params, socket) do
    {:noreply,
     assign(socket,
       busy?: false,
       confirm_key_overwrite: nil,
       error: "Join cancelled — nothing was changed."
     )}
  end

  def handle_event("back", _params, socket),
    do: {:noreply, assign(socket, step: :choose, error: nil)}

  # ── Step 2: Submit details ──────────────────────────────────────────

  def handle_event("submit", params, socket) do
    socket =
      assign(socket,
        password: Map.get(params, "password", ""),
        password_confirm: Map.get(params, "password_confirm", ""),
        node_name: Map.get(params, "node_name", "") |> String.trim(),
        peer_ip: Map.get(params, "peer_ip", "") |> String.trim(),
        token: Map.get(params, "token", "") |> String.trim()
      )

    case validate(socket.assigns) do
      :ok ->
        {:noreply,
         socket
         |> assign(busy?: true, error: nil, step: :provisioning)
         |> tap_send(:provision)}

      {:error, message} ->
        {:noreply, assign(socket, error: message)}
    end
  end

  # ── Provisioning state machine ──────────────────────────────────────

  @impl true
  def handle_info(:provision, socket) do
    a = socket.assigns

    with :ok <- save_node_name(a.node_name),
         :ok <- unlock_keystore(a.password),
         :ok <- start_sidecar() do
      case a.mode do
        :create ->
          # Tailscale is starting in the background, but we don't need it
          # to be authenticated to create the root directory — the genesis
          # node can finish setup offline and authenticate later.
          finish_create(socket)

        :join ->
          # Have to wait for Tailscale to come up and authenticate before
          # we can do the actual cluster join handshake.
          {:noreply,
           socket
           |> assign(step: :await_tailscale, tailscale: fetch_bridge_status())
           |> tap_send_after(:poll_tailscale, 1_500)}
      end
    else
      {:error, message} ->
        {:noreply, assign(socket, busy?: false, error: message, step: :details)}
    end
  end

  def handle_info(:poll_tailscale, socket) do
    ts = fetch_bridge_status()

    if ts_ready?(ts) do
      finish_join(assign(socket, tailscale: ts))
    else
      {:noreply,
       socket
       |> assign(tailscale: ts)
       |> tap_send_after(:poll_tailscale, 2_000)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp finish_create(socket) do
    case create_root() do
      :ok -> push_navigate(socket, to: ~p"/setup/complete?t=#{setup_token()}")
      {:error, msg} -> {:noreply, assign(socket, busy?: false, error: msg, step: :details)}
    end
    |> wrap_noreply()
  end

  defp finish_join(socket, force? \\ false) do
    # Dust.Daemon.Join adopts the network's OTP cookie and master key —
    # fetching them is not enough. It refuses to replace the master key on
    # a node that already holds data unless `force: true` confirms it.
    case Dust.Daemon.Join.join(socket.assigns.peer_ip, socket.assigns.token, force: force?) do
      {:ok, _master_key_outcome} ->
        # The join has genuinely adopted the network's cookie and master
        # key at this point — but Node.self() is fixed for the life of
        # this VM and was set at boot, before this node had its final
        # name. Until the daemon restarts, this node cannot actually
        # complete an Erlang distribution handshake with any peer, no
        # matter how correct the cookie now is. Navigating straight to
        # the dashboard here would look like success while every peer
        # connection silently fails.
        {:noreply, assign(socket, busy?: false, step: :restart_required)}

      {:error, :local_data_exists, local_data} ->
        {:noreply,
         assign(socket,
           busy?: false,
           error: nil,
           confirm_key_overwrite: local_data,
           step: :details
         )}

      {:error, :key_store_locked} ->
        {:noreply,
         assign(socket,
           busy?: false,
           error: "Unlock the key store before joining so the network's master key can be adopted.",
           step: :details
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           busy?: false,
           error: "Could not join network: #{inspect(reason)}",
           step: :details
         )}
    end
  end

  defp local_data_summary(%{shards: :unknown}), do: "amount unknown"

  defp local_data_summary(%{shards: shards, files: files}),
    do: "#{files} file(s), #{shards} stored shard(s)"

  defp local_data_summary(_), do: "amount unknown"

  defp wrap_noreply({:noreply, _socket} = result), do: result
  defp wrap_noreply(socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen items-center justify-center px-6 py-12">
      <div class="w-full max-w-md space-y-6">
        <div class="text-center">
          <h1 class="text-2xl font-bold tracking-tight">Welcome to Dust</h1>
          <p class="mt-1 text-sm text-zinc-500">Let's get your node set up.</p>
        </div>

        <%= case @step do %>
          <% :choose -> %>
            <.choose_mode />
          <% :details -> %>
            <.details
              mode={@mode}
              password={@password}
              password_confirm={@password_confirm}
              node_name={@node_name}
              peer_ip={@peer_ip}
              token={@token}
              error={@error}
              busy?={@busy?}
              confirm_key_overwrite={@confirm_key_overwrite}
            />
          <% :provisioning -> %>
            <.progress_card title="Setting up…">
              <p>Saving device name, unlocking keystore, and starting Tailscale.</p>
            </.progress_card>
          <% :await_tailscale -> %>
            <.await_tailscale_card tailscale={@tailscale} />
          <% :restart_required -> %>
            <.restart_required_card />
        <% end %>
      </div>
    </div>
    """
  end

  defp choose_mode(assigns) do
    ~H"""
    <div class="space-y-3">
      <button
        type="button"
        phx-click="choose_mode"
        phx-value-mode="create"
        class="w-full rounded-lg border border-zinc-200 bg-white p-4 text-left shadow-sm hover:border-zinc-400"
      >
        <p class="font-medium text-zinc-900">Create a new network</p>
        <p class="mt-1 text-sm text-zinc-500">
          This is the first node. You'll invite other devices to join later.
        </p>
      </button>

      <button
        type="button"
        phx-click="choose_mode"
        phx-value-mode="join"
        class="w-full rounded-lg border border-zinc-200 bg-white p-4 text-left shadow-sm hover:border-zinc-400"
      >
        <p class="font-medium text-zinc-900">Join an existing network</p>
        <p class="mt-1 text-sm text-zinc-500">
          You'll need an invite token from another Dust node on your Tailnet.
        </p>
      </button>
    </div>
    """
  end

  defp details(assigns) do
    ~H"""
    <form phx-submit="submit" class="space-y-4 rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
      <p class="text-sm text-zinc-600">
        <%= if @mode == :create do %>
          Set a password and name this device. Tailscale will start once setup begins.
        <% else %>
          Set a password, name this device, and enter the invite from another node.
        <% end %>
      </p>

      <.input
        name="node_name"
        id="node_name"
        label="Device name"
        value={@node_name}
        required
        autocomplete="off"
        placeholder="e.g. laptop"
      />

      <.input
        name="password"
        id="password"
        type="password"
        label="Keystore password"
        value={@password}
        required
        autocomplete="new-password"
      />

      <.input
        name="password_confirm"
        id="password_confirm"
        type="password"
        label="Confirm password"
        value={@password_confirm}
        required
        autocomplete="new-password"
      />

      <%= if @mode == :join do %>
        <.input
          name="peer_ip"
          id="peer_ip"
          label="Peer Tailscale IP"
          value={@peer_ip}
          required
          autocomplete="off"
          placeholder="100.64.0.X"
        />
        <.input
          name="token"
          id="token"
          label="Invite token"
          value={@token}
          required
          autocomplete="off"
        />
      <% end %>

      <p :if={@error} class="text-sm text-rose-600">{@error}</p>

      <div
        :if={@confirm_key_overwrite}
        class="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm"
      >
        <p class="font-medium text-amber-900">This node already holds data</p>
        <p class="mt-1 text-amber-800">
          Joining adopts the network's master key. Data stored under this node's
          current key ({local_data_summary(@confirm_key_overwrite)}) becomes
          permanently unreadable.
        </p>
        <div class="mt-3 flex items-center gap-3">
          <.button type="button" phx-click="confirm_key_overwrite">
            Join and replace key
          </.button>
          <button
            type="button"
            phx-click="cancel_key_overwrite"
            class="text-sm text-zinc-600 hover:text-zinc-900"
          >
            Cancel
          </button>
        </div>
      </div>

      <div class="flex items-center justify-between gap-2 pt-2">
        <button
          type="button"
          phx-click="back"
          class="text-sm text-zinc-500 hover:text-zinc-900"
        >
          Back
        </button>

        <.button type="submit" {%{disabled: @busy? or not is_nil(@confirm_key_overwrite)}}>
          {if @busy?, do: "Setting up…", else: submit_label(@mode)}
        </.button>
      </div>
    </form>
    """
  end

  defp progress_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-white p-6 text-sm shadow-sm">
      <p class="font-medium text-zinc-900">{@title}</p>
      <div class="mt-2 text-zinc-600">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :tailscale, :map, required: true
  slot :inner_block

  defp await_tailscale_card(assigns) do
    ~H"""
    <div class="space-y-4 rounded-lg border border-amber-200 bg-amber-50 p-6 text-sm text-amber-900 shadow-sm">
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="font-medium">Waiting for Tailscale</p>
          <p class="mt-0.5 text-xs uppercase tracking-wide">
            {ts_label(@tailscale)}
          </p>
        </div>
        <span class="rounded-full bg-amber-200 px-2 py-0.5 text-xs font-semibold">waiting</span>
      </div>

      <div :if={@tailscale.auth_url} class="border-t border-amber-200 pt-3 text-xs">
        <p>Open this URL on any device to authenticate this node:</p>
        <a
          href={@tailscale.auth_url}
          target="_blank"
          rel="noopener"
          class="mt-1 inline-block break-all font-mono underline"
        >
          {@tailscale.auth_url}
        </a>
      </div>

      <p class="text-xs">
        Once Tailscale is authenticated, this page will continue automatically.
      </p>
    </div>
    """
  end

  defp restart_required_card(assigns) do
    ~H"""
    <div class="space-y-4 rounded-lg border border-amber-200 bg-amber-50 p-6 text-sm text-amber-900 shadow-sm">
      <div>
        <p class="font-medium">Joined — one more step</p>
        <p class="mt-1 text-amber-800">
          This node has adopted the network's credentials, but it won't actually
          be reachable by other nodes until the Dust daemon restarts. Erlang
          (the runtime Dust is built on) fixes a node's identity when it starts
          up, and this node was still using its placeholder identity when setup
          began.
        </p>
      </div>

      <div class="space-y-3 border-t border-amber-200 pt-3 text-xs">
        <div>
          <p class="font-medium uppercase tracking-wide">Linux (systemd)</p>
          <code class="mt-1 block rounded bg-amber-100 px-2 py-1 font-mono">
            sudo systemctl restart dust
          </code>
        </div>

        <div>
          <p class="font-medium uppercase tracking-wide">macOS (launchd)</p>
          <code class="mt-1 block rounded bg-amber-100 px-2 py-1 font-mono">
            launchctl unload ~/Library/LaunchAgents/com.dust.daemon.plist<br />
            launchctl load ~/Library/LaunchAgents/com.dust.daemon.plist
          </code>
        </div>

        <div>
          <p class="font-medium uppercase tracking-wide">Windows</p>
          <code class="mt-1 block rounded bg-amber-100 px-2 py-1 font-mono">
            net stop dust && net start dust
          </code>
        </div>

        <div>
          <p class="font-medium uppercase tracking-wide">Manually-started daemon</p>
          <code class="mt-1 block rounded bg-amber-100 px-2 py-1 font-mono">
            dustctl daemon stop && dustctl daemon start
          </code>
        </div>
      </div>

      <p class="border-t border-amber-200 pt-3 text-xs">
        After restarting, reload this page and log in with your keystore
        password — the network connection will be complete.
      </p>
    </div>
    """
  end

  defp submit_label(:create), do: "Create network"
  defp submit_label(:join), do: "Join network"

  defp ts_ready?(%{state: "authenticated", self_ip: ip}) when is_binary(ip) and ip != "",
    do: true

  defp ts_ready?(_), do: false

  defp ts_label(%{state: "authenticated"}), do: "Connected"
  defp ts_label(%{state: "needs_auth"}), do: "Needs authentication"
  defp ts_label(%{state: "unavailable"}), do: "Starting…"
  defp ts_label(%{state: state}), do: state || "Unknown"

  # ── Validation ──────────────────────────────────────────────────────

  defp validate(assigns) do
    cond do
      assigns.password == "" ->
        {:error, "Password is required."}

      byte_size(assigns.password) < 8 ->
        {:error, "Password must be at least 8 characters."}

      assigns.password != assigns.password_confirm ->
        {:error, "Passwords do not match."}

      assigns.node_name == "" ->
        {:error, "Device name is required."}

      not Regex.match?(@node_name_pattern, assigns.node_name) ->
        {:error,
         "Device name must start with a letter or digit and use only letters, digits, '-', or '_'."}

      assigns.mode == :join and assigns.peer_ip == "" ->
        {:error, "Peer IP is required to join."}

      assigns.mode == :join and assigns.token == "" ->
        {:error, "Invite token is required to join."}

      true ->
        :ok
    end
  end

  # ── Provision helpers ───────────────────────────────────────────────

  defp save_node_name(name) do
    case Dust.Utilities.Config.put(:node_name, name) do
      :ok -> :ok
      {:error, reason} -> {:error, "Could not save device name: #{inspect(reason)}"}
    end
  end

  defp unlock_keystore(password) do
    case Dust.Core.KeyStore.unlock(password) do
      :ok ->
        :ok

      {:error, :already_unlocked} ->
        :ok

      {:error, :decrypt_failed} ->
        {:error, "Keystore is already initialized with a different password."}

      {:error, reason} ->
        {:error, "Could not unlock keystore: #{inspect(reason)}"}
    end
  end

  defp start_sidecar do
    case Dust.Bridge.start_sidecar() do
      :ok -> :ok
      {:error, reason} -> {:error, "Could not start Tailscale: #{inspect(reason)}"}
    end
  end

  defp create_root do
    case Dust.Mesh.FileSystem.mkdir(nil, "/") do
      {:ok, root_id} ->
        _ = Dust.Utilities.Config.put(:root_dir_id, root_id)
        :ok

      {:error, :root_already_exists} ->
        case Enum.find(Dust.Mesh.FileSystem.all_dirs(), fn {_id, d} ->
               Map.get(d, :parent_id) == nil
             end) do
          {id, _} ->
            _ = Dust.Utilities.Config.put(:root_dir_id, id)
            :ok

          _ ->
            :ok
        end

      {:error, reason} ->
        {:error, "Could not create root directory: #{inspect(reason)}"}
    end
  end

  defp fetch_bridge_status do
    bridge = Application.get_env(:dust_bridge, :bridge_module, Dust.Bridge)

    try do
      case bridge.auth_status() do
        {:ok, info} -> Map.merge(%{state: "unknown", self_ip: nil, auth_url: nil}, info)
        _ -> %{state: "unavailable", self_ip: nil, auth_url: nil}
      end
    rescue
      _ -> %{state: "unavailable", self_ip: nil, auth_url: nil}
    catch
      :exit, _ -> %{state: "unavailable", self_ip: nil, auth_url: nil}
    end
  end

  defp setup_token,
    do: Phoenix.Token.sign(Dust.Ui.Endpoint, "setup_complete", true, max_age: 60)

  defp tap_send(socket, msg) do
    send(self(), msg)
    socket
  end

  defp tap_send_after(socket, msg, ms) do
    Process.send_after(self(), msg, ms)
    socket
  end
end
