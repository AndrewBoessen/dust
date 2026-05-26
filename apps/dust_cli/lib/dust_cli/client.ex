defmodule Dust.CLI.Client do
  @moduledoc """
  HTTP client for communicating with the Dust daemon API.

  Uses Erlang's built-in `:httpc` — no external HTTP library required.
  Automatically reads the bearer token from `<data_dir>/api_token`.
  """

  @timeout 30_000

  @doc "Build a base URL from config."
  def base_url(%{host: host, port: port}) do
    "http://#{host}:#{port}"
  end

  @doc "Perform a GET request."
  def get(config, path) do
    url = "#{base_url(config)}#{path}"

    headers = auth_headers(config)

    case :httpc.request(:get, {to_charlist(url), headers}, http_opts(), []) do
      {:ok, {{_, status, _}, _headers, body}} ->
        {status, decode_body(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Perform a POST request with a JSON body."
  def post(config, path, body \\ %{}) do
    url = "#{base_url(config)}#{path}"

    headers = auth_headers(config)
    json_body = Jason.encode!(body)

    case :httpc.request(
           :post,
           {to_charlist(url), headers, ~c"application/json", json_body},
           http_opts(),
           []
         ) do
      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {status, decode_body(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Perform a PUT request with a JSON body."
  def put(config, path, body \\ %{}) do
    url = "#{base_url(config)}#{path}"

    headers = auth_headers(config)
    json_body = Jason.encode!(body)

    case :httpc.request(
           :put,
           {to_charlist(url), headers, ~c"application/json", json_body},
           http_opts(),
           []
         ) do
      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {status, decode_body(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Perform a DELETE request."
  def delete(config, path) do
    url = "#{base_url(config)}#{path}"

    headers = auth_headers(config)

    case :httpc.request(:delete, {to_charlist(url), headers}, http_opts(), []) do
      {:ok, {{_, status, _}, _headers, body}} ->
        {status, decode_body(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stream a local file as the body of a POST request.

  Sends `Content-Type: application/octet-stream` with `extra_headers`
  appended after the bearer-auth header. The file is read with the
  CLI's own permissions in 4 MB chunks; `:httpc`'s built-in chunkifier
  encodes them as HTTP/1.1 `Transfer-Encoding: chunked`, so memory use
  stays bounded regardless of file size.

  `progress_fn` is invoked with the byte count of each chunk as it's
  queued for the wire. Defaults to a no-op. Sums to the file size.

  Returns `{status, decoded_body}` on a completed response, or
  `{:error, reason}` for transport failures.
  """
  @spec post_stream(
          map(),
          String.t(),
          [{String.t(), String.t()}],
          Path.t(),
          (non_neg_integer() -> any())
        ) ::
          {non_neg_integer(), {:ok, term()} | {:error, term()}} | {:error, term()}
  def post_stream(config, path, extra_headers, body_path, progress_fn \\ fn _ -> :ok end) do
    url = "#{base_url(config)}#{path}"

    # `:httpc` only emits `Transfer-Encoding: chunked` when you use the
    # explicit `{:chunkify, fun, acc}` body form. The plain `{fun, acc}`
    # form expects the caller to declare the size up front via
    # `Content-Length`; without it httpc sends a body-less request that
    # the server reads as zero bytes (Bandit then 400s the dangling
    # socket — visible as the "unexpected :tcp data" warning in
    # httpc_manager). We have the size locally, so set it.
    with {:ok, %File.Stat{size: size}} <- File.stat(body_path),
         {:ok, file} <- File.open(body_path, [:read, :binary]) do
      headers =
        auth_headers(config) ++
          [{~c"content-length", to_charlist(Integer.to_string(size))}] ++
          Enum.map(extra_headers, fn {k, v} ->
            {to_charlist(k), to_charlist(v)}
          end)

      try do
        chunkifier = build_chunkifier(progress_fn, body_path)

        result =
          :httpc.request(
            :post,
            {to_charlist(url), headers, ~c"application/octet-stream",
             {chunkifier, file}},
            http_opts(),
            []
          )

        case result do
          {:ok, {{_, status, _}, _h, body}} -> {status, decode_body(body)}
          {:error, reason} -> {:error, reason}
        end
      after
        File.close(file)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stream a GET response body straight to `dest_path` on disk.

  Uses `:httpc`'s `[{:stream, path}]` option, so the CLI writes the
  response with its own permissions — the daemon never opens a
  user-side file. On 200 returns `{200, :saved_to_file}`; on non-200
  the response is read into memory and returned as
  `{status, decoded_body}` so callers can surface the error.
  """
  @spec get_to_file(map(), String.t(), Path.t()) ::
          {non_neg_integer(), :saved_to_file | {:ok, term()} | {:error, term()}}
          | {:error, term()}
  def get_to_file(config, path, dest_path) do
    url = "#{base_url(config)}#{path}"
    headers = auth_headers(config)

    case :httpc.request(
           :get,
           {to_charlist(url), headers},
           http_opts(),
           [{:stream, to_charlist(dest_path)}]
         ) do
      {:ok, :saved_to_file} ->
        {200, :saved_to_file}

      {:ok, {{_, status, _}, _h, body}} ->
        {status, decode_body(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Check if the daemon is reachable."
  def ping(config) do
    case get(config, "/api/v1/status") do
      {200, _body} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # 4 MB per body chunk — matches the daemon's `Packer` chunking on the
  # ingest side, so on the local-only path the network buffer and the
  # disk read-ahead align.
  @stream_chunk_size 4 * 1024 * 1024

  # ── Private ────────────────────────────────────────────────────────────

  # Builds the `{fun, acc}` body callback for `:httpc.request/4`.
  # Each invocation reads the next chunk from the open file device and
  # reports the chunk size as a delta to `progress_fn`. `path` is
  # captured only for error reporting.
  defp build_chunkifier(progress_fn, path) do
    fn file ->
      case IO.binread(file, @stream_chunk_size) do
        :eof ->
          :eof

        data when is_binary(data) ->
          _ = progress_fn.(byte_size(data))
          {:ok, [data], file}

        {:error, reason} ->
          raise File.Error, reason: reason, action: "stream", path: path
      end
    end
  end

  defp auth_headers(config) do
    case read_token(config) do
      {:ok, token} ->
        [{~c"authorization", to_charlist("Bearer #{token}")}]

      _ ->
        []
    end
  end

  defp read_token(%{token: token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp read_token(%{data_dir: data_dir}) do
    path = Path.join(data_dir, "api_token")

    case File.read(path) do
      {:ok, token} -> {:ok, String.trim(token)}
      error -> error
    end
  end

  defp decode_body(body) when is_list(body) do
    body |> to_string() |> Jason.decode()
  end

  defp decode_body(body) when is_binary(body) do
    Jason.decode(body)
  end

  defp http_opts do
    [timeout: @timeout, connect_timeout: 5_000]
  end
end
