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
        nil -> Owl.IO.input(label: "Password", secret: true)
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

        other ->
          Formatter.api_error(other)
      end
    end
  end

  def lock(config, _args) do
    case Client.post(config, "/api/v1/lock") do
      {200, {:ok, %{"status" => "locked"}}} ->
        Formatter.success("Key store locked")
        0

      other ->
        Formatter.api_error(other)
    end
  end
end
