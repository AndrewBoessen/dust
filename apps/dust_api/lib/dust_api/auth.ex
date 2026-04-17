defmodule Dust.Api.Auth do
  @moduledoc """
  Bearer-token authentication for the Dust API.

  On first daemon start a random 32-byte token is generated, hex-encoded,
  and persisted to `<persist_dir>/api_token`. The CLI reads this file
  automatically; the web UI asks the user to paste it once per session.

  ## Token lifecycle

    * Generated once and persisted at `<persist_dir>/api_token`.
    * Regenerated via `regenerate_token!/0` (invalidates all existing sessions).
    * Validated on every request via the `Dust.Api.Auth.Plug` plug.

  ## Authentication

  Requests must include an `Authorization: Bearer <token>` header.
  The `/api/v1/status` endpoint is exempt (returns basic liveness only).
  """

  require Logger

  @token_filename "api_token"
  @token_bytes 32

  # ── Token management ───────────────────────────────────────────────────

  @doc """
  Ensures an API token file exists on disk. Generates one if missing.

  Called automatically by `Dust.Api.Application` at boot.
  """
  @spec ensure_token!() :: :ok
  def ensure_token! do
    path = token_path()

    unless File.exists?(path) do
      token = generate_token()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, token)
      # Restrict permissions on Unix
      set_file_permissions(path)
      Logger.info("Dust.Api.Auth: generated new API token at #{path}")
    end

    :ok
  end

  @doc """
  Regenerates the API token, invalidating any existing sessions.
  """
  @spec regenerate_token!() :: String.t()
  def regenerate_token! do
    token = generate_token()
    path = token_path()
    File.write!(path, token)
    set_file_permissions(path)
    Logger.info("Dust.Api.Auth: regenerated API token")
    token
  end

  @doc """
  Reads the current API token from disk.
  """
  @spec read_token() :: {:ok, String.t()} | {:error, File.posix()}
  def read_token do
    case File.read(token_path()) do
      {:ok, token} -> {:ok, String.trim(token)}
      error -> error
    end
  end

  @doc "Absolute path to the API token file."
  @spec token_path() :: Path.t()
  def token_path do
    Path.join(Dust.Utilities.Config.persist_dir(), @token_filename)
  end

  # ── Plug ────────────────────────────────────────────────────────────────

  defmodule Plug do
    @moduledoc """
    Plug that validates bearer tokens on incoming requests.

    Exempt paths (no auth required):
      - `GET /api/v1/status`
    """

    import Elixir.Plug.Conn

    @behaviour Elixir.Plug

    @exempt_paths [{:GET, "/api/v1/status"}]

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      if exempt?(conn) do
        conn
      else
        validate_token(conn)
      end
    end

    defp exempt?(conn) do
      method = conn.method |> String.upcase() |> String.to_atom()
      {method, conn.request_path} in @exempt_paths
    end

    defp validate_token(conn) do
      with [auth_header | _] <- get_req_header(conn, "authorization"),
           "Bearer " <> token <- auth_header,
           {:ok, expected} <- Dust.Api.Auth.read_token(),
           true <- Elixir.Plug.Crypto.secure_compare(String.trim(token), expected) do
        conn
      else
        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
          |> halt()
      end
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec generate_token() :: String.t()
  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.encode16(case: :lower)
  end

  @spec set_file_permissions(Path.t()) :: :ok
  defp set_file_permissions(path) do
    case :os.type() do
      {:unix, _} -> File.chmod!(path, 0o600)
      _ -> :ok
    end
  end
end
