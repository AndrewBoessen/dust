defmodule Dust.Ui.SetupLive do
  @moduledoc """
  First-time setup wizard.

  Mirrors `dustctl init`: pick a password, pick a node name, and either
  create a new network (mkdir root) or join an existing one (peer IP +
  invite token).

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
      if connected?(socket), do: Process.send_after(self(), :poll_bridge, 2500)

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
         tailscale: fetch_bridge_status()
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
        socket = assign(socket, busy?: true, error: nil)
        {:noreply, run_setup(socket)}

      {:error, message} ->
        {:noreply, assign(socket, error: message)}
    end
  end

  @impl true
  def handle_info(:poll_bridge, socket) do
    Process.send_after(self(), :poll_bridge, 2500)
    {:noreply, assign(socket, tailscale: fetch_bridge_status())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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
            <.tailscale_panel tailscale={@tailscale} mode={@mode} />
            <.details
              mode={@mode}
              password={@password}
              password_confirm={@password_confirm}
              node_name={@node_name}
              peer_ip={@peer_ip}
              token={@token}
              error={@error}
              busy?={@busy?}
              tailscale_ready?={ts_ready?(@tailscale)}
            />
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

  defp tailscale_panel(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border p-4 text-sm shadow-sm",
      ready_class(@tailscale)
    ]}>
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="font-medium">Tailscale</p>
          <p class="mt-0.5 text-xs uppercase tracking-wide">
            {ts_label(@tailscale)}
          </p>
          <p :if={@tailscale.self_ip} class="mt-1 font-mono text-xs">
            IP {@tailscale.self_ip}
          </p>
        </div>
        <span class={[
          "rounded-full px-2 py-0.5 text-xs font-semibold",
          ready_pill(@tailscale)
        ]}>
          {if ts_ready?(@tailscale), do: "ready", else: "waiting"}
        </span>
      </div>

      <div :if={@tailscale.auth_url} class="mt-3 border-t border-current/10 pt-3 text-xs">
        <p>
          Open this URL on any device to authenticate this node:
        </p>
        <a
          href={@tailscale.auth_url}
          target="_blank"
          rel="noopener"
          class="mt-1 inline-block break-all font-mono underline"
        >
          {@tailscale.auth_url}
        </a>
        <p class="mt-2 text-zinc-500">
          This panel updates every few seconds — no need to refresh.
        </p>
      </div>

      <p :if={@mode == :join and not ts_ready?(@tailscale)} class="mt-3 border-t border-current/10 pt-3 text-xs">
        You need Tailscale authenticated before you can join an existing network.
      </p>
    </div>
    """
  end

  defp ts_ready?(%{state: "authenticated", self_ip: ip}) when is_binary(ip) and ip != "",
    do: true

  defp ts_ready?(_), do: false

  defp ts_label(%{state: "authenticated"}), do: "Connected"
  defp ts_label(%{state: "needs_auth"}), do: "Needs authentication"
  defp ts_label(%{state: "unavailable"}), do: "Bridge unavailable"
  defp ts_label(%{state: state}), do: state || "Unknown"

  defp ready_class(ts) do
    if ts_ready?(ts),
      do: "border-emerald-200 bg-emerald-50 text-emerald-900",
      else: "border-amber-200 bg-amber-50 text-amber-900"
  end

  defp ready_pill(ts) do
    if ts_ready?(ts),
      do: "bg-emerald-200 text-emerald-900",
      else: "bg-amber-200 text-amber-900"
  end

  defp details(assigns) do
    ~H"""
    <form phx-submit="submit" class="space-y-4 rounded-lg border border-zinc-200 bg-white p-6 shadow-sm">
      <p class="text-sm text-zinc-600">
        <%= if @mode == :create do %>
          Set a password and name this device.
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

      <div class="flex items-center justify-between gap-2 pt-2">
        <button
          type="button"
          phx-click="back"
          class="text-sm text-zinc-500 hover:text-zinc-900"
        >
          Back
        </button>

        <.button type="submit" {%{disabled: @busy? or submit_disabled?(@mode, @tailscale_ready?)}}>
          {if @busy?, do: "Setting up…", else: submit_label(@mode)}
        </.button>
      </div>
    </form>
    """
  end

  defp submit_label(:create), do: "Create network"
  defp submit_label(:join), do: "Join network"

  defp submit_disabled?(:join, ready?), do: not ready?
  defp submit_disabled?(_, _), do: false

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

      assigns.mode == :join and not tailscale_ready?(assigns.tailscale) ->
        {:error, "Tailscale isn't authenticated yet. Complete the auth step above and try again."}

      true ->
        :ok
    end
  end

  defp tailscale_ready?(%{state: "authenticated", self_ip: ip}) when is_binary(ip) and ip != "",
    do: true

  defp tailscale_ready?(_), do: false

  # ── Setup runner ────────────────────────────────────────────────────

  defp run_setup(socket) do
    a = socket.assigns

    with :ok <- unlock_keystore(a.password),
         :ok <- save_node_name(a.node_name),
         :ok <- run_mode(a.mode, a.peer_ip, a.token) do
      token =
        Phoenix.Token.sign(Dust.Ui.Endpoint, "setup_complete", true, max_age: 60)

      push_navigate(socket, to: ~p"/setup/complete?t=#{token}")
    else
      {:error, message} ->
        assign(socket, busy?: false, error: message)
    end
  end

  defp unlock_keystore(password) do
    case Dust.Core.KeyStore.unlock(password) do
      :ok -> :ok
      {:error, :already_unlocked} -> :ok
      {:error, :decrypt_failed} -> {:error, "Keystore is already initialized with a different password."}
      {:error, reason} -> {:error, "Could not unlock keystore: #{inspect(reason)}"}
    end
  end

  defp save_node_name(name) do
    case Dust.Utilities.Config.put(:node_name, name) do
      :ok -> :ok
      {:error, reason} -> {:error, "Could not save device name: #{inspect(reason)}"}
    end
  end

  defp run_mode(:create, _peer_ip, _token) do
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

  defp run_mode(:join, peer_ip, token) do
    bridge = Application.get_env(:dust_bridge, :bridge_module, Dust.Bridge)

    case bridge.join(peer_ip, token) do
      {:ok, _master_key, _otp_cookie} ->
        :ok

      {:error, reason} ->
        {:error, "Could not join network: #{inspect(reason)}"}
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
end
