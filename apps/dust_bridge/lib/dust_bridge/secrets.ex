defmodule Dust.Bridge.Secrets do
  @moduledoc """
  Manages the Erlang OTP cookie distribution and caches the Master Key fetch on join.

  The Secrets agent is responsible for ensuring that all nodes in the mesh
  can communicate by securely distributing and applying the same OTP cookie.
  During `setup/0`, if a node does not have an existing cookie (e.g. initial boot),
  it will request it securely over an authenticated Tailscale connection using a
  one-time invitation token, simultaneously picking up the Master Key for the
  shared cluster keystore.
  """
  use Agent
  require Logger

  @secrets_file "secrets.json"

  def start_link(_) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  def get_fetched_master_key() do
    if Process.whereis(__MODULE__) do
      Agent.get(__MODULE__, & &1)
    else
      nil
    end
  end

  def clear_fetched_master_key() do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn _ -> nil end)
    end
  end

  def store_fetched_master_key(master_key_b64) do
    Agent.update(__MODULE__, fn _ -> master_key_b64 end)
  end

  @doc """
  Initializes the node's secrets at startup.

  1. Checks if an OTP cookie already exists locally (in the TS state dir).
  2. If it exists, it loads and applies the cookie.
  3. If missing, and `JOIN_IP` / `JOIN_TOKEN` environments are provided, it initiates a secure
     join process over Tailscale. The token is sent to the peer, and the secrets (OTP cookie
     and Master Key) are retrieved.
  4. If neither condition is met, it assumes it is the first node (genesis) and creates a
     new securely randomized OTP cookie.

  It caches the Master Key (if retrieved) so the rest of the app can pick it up.
  """
  def setup() do
    secrets_path = get_secrets_path()

    if File.exists?(secrets_path) do
      Logger.info("Bridge Secrets: Found existing OTP cookie, loading...")
      load_and_apply_cookie(secrets_path)
    else
      join_ip = System.get_env("JOIN_IP")
      join_token = System.get_env("JOIN_TOKEN")

      if join_ip && join_token do
        Logger.info("Bridge Secrets: Attempting to join mesh via #{join_ip}...")
        join_mesh(join_ip, join_token, secrets_path)
      else
        Logger.info("Bridge Secrets: No secrets found and no join config. Generating genesis OTP cookie...")
        generate_genesis_cookie(secrets_path)
      end
    end
  end

  defp load_and_apply_cookie(path) do
    case File.read(path) do
      {:ok, cookie} ->
        cookie = String.trim(cookie)
        apply_cookie(cookie)

      {:error, reason} ->
        Logger.error("Bridge Secrets: Failed to read secrets file: #{inspect(reason)}")
    end
  end

  defp join_mesh(ip, token, path) do
    case Dust.Bridge.join(ip, token) do
      {:ok, master_key_b64, otp_cookie} ->
        Logger.info("Bridge Secrets: Successfully fetched secrets from peer!")
        save_cookie(path, otp_cookie)
        apply_cookie(otp_cookie)
        store_fetched_master_key(master_key_b64)

      {:error, reason} ->
        Logger.error("Bridge Secrets: Failed to join mesh: #{inspect(reason)}. Continuing without secrets.")
    end
  end

  defp generate_genesis_cookie(path) do
    otp_cookie = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    save_cookie(path, otp_cookie)
    apply_cookie(otp_cookie)
  end

  defp save_cookie(path, otp_cookie) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, otp_cookie)
    File.chmod!(path, 0o600)
    Logger.info("Bridge Secrets: OTP Cookie saved securely to #{path}")
  end

  defp apply_cookie(otp_cookie) do
    if Node.alive?() do
      Node.set_cookie(Node.self(), String.to_atom(otp_cookie))
      Logger.info("Bridge Secrets: Erlang OTP cookie set.")
    else
      Logger.warning("Bridge Secrets: Node is not alive! Cannot set OTP cookie.")
    end
  end

  defp get_secrets_path() do
    node_prefix = Node.self() |> to_string() |> String.split("@") |> List.first() || "unknown"
    home_dir = System.user_home!()
    default_state_dir = Path.join([home_dir, ".dust", "tsnet-state-#{node_prefix}"])
    state_dir = System.get_env("TS_STATE_DIR") || default_state_dir
    Path.join(state_dir, @secrets_file)
  end
end
