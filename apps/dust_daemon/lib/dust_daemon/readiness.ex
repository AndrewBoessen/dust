defmodule Dust.Daemon.Readiness do
  @moduledoc """
  Global "system ready" flag backed by `:persistent_term`.

  The bootstrapper calls `set_ready/0` once all startup validation
  phases have completed. Other subsystems can check `ready?/0` before
  performing destructive or data-sensitive operations (e.g. GC sweeps,
  repair sweeps).

  `:persistent_term` is chosen over ETS/Agent because reads are
  effectively free (no message passing or process lookup) and the flag
  is written exactly once per boot.
  """

  @key {__MODULE__, :ready}

  @doc """
  Marks the system as bootstrapped.

  Should only be called once by `Dust.Daemon.Bootstrapper` at the end
  of a successful startup sequence.
  """
  @spec set_ready() :: :ok
  def set_ready do
    :persistent_term.put(@key, true)
    :ok
  end

  @doc """
  Returns `true` if the system has been fully bootstrapped, `false` otherwise.

  This is a zero-cost read in the hot path — no process, no message, no ETS.
  """
  @spec ready?() :: boolean()
  def ready? do
    :persistent_term.get(@key, false)
  end

  @doc """
  Blocks the caller until the system is ready or `timeout_ms` elapses.

  Primarily intended for test scaffolding or external tooling that needs
  to wait for a fully bootstrapped node.

  Returns `:ok` when ready, or `{:error, :timeout}` if the deadline expires.
  """
  @spec await_ready(pos_integer()) :: :ok | {:error, :timeout}
  def await_ready(timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until_ready(deadline)
  end

  @spec poll_until_ready(integer()) :: :ok | {:error, :timeout}
  defp poll_until_ready(deadline) do
    if ready?() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(100)
        poll_until_ready(deadline)
      end
    end
  end
end
