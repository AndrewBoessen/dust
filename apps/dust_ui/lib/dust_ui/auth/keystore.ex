defmodule Dust.Ui.Auth.Keystore do
  @moduledoc """
  Thin wrapper around `Dust.Core.KeyStore` for the web UI.

  Mirrors the unlock/lock semantics of `Dust.Api.Handlers.KeystoreHandler` so
  that logging in through the UI has the same effect as `dustctl unlock`.
  """

  @doc """
  Attempts to unlock the keystore with the given password.

  Returns `:ok` on success, `{:error, :invalid_password}` for a wrong
  password, or `{:error, reason}` for anything else.
  """
  @spec unlock(String.t()) :: :ok | {:error, :invalid_password | term()}
  def unlock(password) when is_binary(password) and password != "" do
    case Dust.Core.KeyStore.unlock(password) do
      :ok -> :ok
      {:error, :decrypt_failed} -> {:error, :invalid_password}
      {:error, :already_unlocked} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def unlock(_), do: {:error, :invalid_password}

  @doc "Locks the keystore."
  @spec lock() :: :ok
  def lock, do: Dust.Core.KeyStore.lock()

  @doc "Returns true if the keystore is currently unlocked."
  @spec unlocked?() :: boolean()
  def unlocked?, do: Dust.Core.KeyStore.has_key?()
end
