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

  @doc "Check if the daemon is reachable."
  def ping(config) do
    case get(config, "/api/v1/status") do
      {200, _body} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # ── Private ────────────────────────────────────────────────────────────

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
