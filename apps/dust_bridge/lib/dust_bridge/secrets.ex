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

  @doc false
  @spec start_link(term()) :: Agent.on_start()
  def start_link(_) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc """
  Returns the base-64 encoded master key fetched during a mesh join,
  or `nil` if no key has been cached.

  Safe to call even if the Agent has not been started (returns `nil`).
  """
  @spec get_fetched_master_key() :: String.t() | nil
  def get_fetched_master_key() do
    if Process.whereis(__MODULE__) do
      Agent.get(__MODULE__, & &1)
    else
      nil
    end
  end

  @doc """
  Clears the cached master key so it cannot be read again.

  Called by `Dust.Core.KeyStore` immediately after adopting the key.
  No-op if the Agent is not running.
  """
  @spec clear_fetched_master_key() :: :ok
  def clear_fetched_master_key() do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn _ -> nil end)
    end

    :ok
  end

  @doc "Caches a base-64 encoded master key obtained from a peer node."
  @spec store_fetched_master_key(String.t()) :: :ok
  def store_fetched_master_key(master_key_b64) do
    Agent.update(__MODULE__, fn _ -> master_key_b64 end)
  end

  @doc """
  Initializes the node's OTP cookie at startup.

  The function follows a three-step precedence:

  1. **Existing cookie** — If a cookie file already exists on disk, it is
     loaded and applied via `Node.set_cookie/2`.
  2. **Mesh join** — If `JOIN_IP` and `JOIN_TOKEN` environment variables are
     set, the node contacts the specified peer over Tailscale to retrieve
     the OTP cookie and master key. The master key is cached in this Agent
     for `Dust.Core.KeyStore` to adopt on unlock.
  3. **Genesis** — If no cookie exists and no join config is provided, a
     fresh random cookie is generated for a new, standalone network.
  """
  @spec setup() :: :ok
  def setup() do
    secrets_path = Dust.Utilities.File.secrets_file()

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
        Logger.info(
          "Bridge Secrets: No secrets found and no join config. Generating genesis OTP cookie..."
        )

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
        Logger.error(
          "Bridge Secrets: Failed to join mesh: #{inspect(reason)}. Continuing without secrets."
        )
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
end
