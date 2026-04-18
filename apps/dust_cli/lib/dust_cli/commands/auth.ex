defmodule Dust.CLI.Commands.Auth do
  @moduledoc """
  Handles key store authentication:

      dustctl unlock
      dustctl lock
  """

  alias Dust.CLI.{Client, Formatter}

  def unlock(config, args) do
    {opts, _, _} = OptionParser.parse(args, strict: [password: :string], aliases: [p: :password])

    password =
      case Keyword.get(opts, :password) do
        nil -> get_secret("Password: ")
        p -> p
      end

    if password == "" do
      Formatter.error("Password cannot be empty")
      1
    else
      case Client.post(config, "/api/v1/unlock", %{password: password}) do
        {200, {:ok, %{"status" => "unlocked"}}} ->
          Formatter.success("Key store unlocked")
          0

        {200, {:ok, %{"status" => "already_unlocked"}}} ->
          Formatter.success("Key store is already unlocked")
          0

        {401, {:ok, %{"error" => "invalid_password"}}} ->
          Formatter.error("Invalid password")
          1

        {401, {:ok, %{"error" => "unauthorized"}}} ->
          Formatter.error("API authentication failed — check your api_token")
          1

        {:error, {:failed_connect, _}} ->
          Formatter.daemon_unreachable()
          1

        other ->
          Formatter.error("Unexpected response: #{inspect(other)}")
          1
      end
    end
  end

  def lock(config, _args) do
    case Client.post(config, "/api/v1/lock") do
      {200, {:ok, %{"status" => "locked"}}} ->
        Formatter.success("Key store locked")
        0

      {:error, {:failed_connect, _}} ->
        Formatter.daemon_unreachable()
        1

      other ->
        Formatter.error("Unexpected response: #{inspect(other)}")
        1
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  def get_secret(prompt) do
    pid = spawn_link(fn -> loop(prompt) end)
    ref = make_ref()
    value = IO.gets("#{prompt}: ")
    send(pid, {:done, self(), ref})
    receive do
      {:done, ^pid, ^ref} -> :ok
    end
    value |> String.trim()
  end

  defp loop(prompt) do
    receive do
      {:done, parent, ref} ->
        send(parent, {:done, self(), ref})
        IO.write(:standard_error, "\e[2K\r")
    after
      1 ->
        IO.write(:standard_error, "\e[2K\r#{prompt}: ")
        loop(prompt)
    end
  end
end
