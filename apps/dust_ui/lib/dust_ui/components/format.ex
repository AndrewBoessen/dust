defmodule Dust.Ui.Format do
  @moduledoc """
  Display-format helpers shared across LiveViews and components.
  """

  @units ["B", "KB", "MB", "GB", "TB", "PB"]

  @doc """
  Formats a byte count as a human-readable string (1.4 GB, 532 KB, …).
  """
  @spec bytes(integer() | nil) :: String.t()
  def bytes(nil), do: "—"
  def bytes(0), do: "0 B"

  def bytes(n) when is_integer(n) and n > 0 do
    exp = min(trunc(:math.log(n) / :math.log(1024)), length(@units) - 1)
    val = n / :math.pow(1024, exp)
    unit = Enum.at(@units, exp)
    "#{:erlang.float_to_binary(val, decimals: precision(val))} #{unit}"
  end

  def bytes(_), do: "—"

  defp precision(v) when v >= 100, do: 0
  defp precision(v) when v >= 10, do: 1
  defp precision(_), do: 2

  @doc """
  Formats a percentage (0.0..1.0) clamped and rounded.
  """
  @spec percent(float() | integer() | nil, integer()) :: String.t()
  def percent(ratio, decimals \\ 0)
  def percent(nil, _decimals), do: "—"
  def percent(0, _decimals), do: "0%"

  def percent(ratio, decimals) when is_number(ratio) do
    clamped = ratio |> min(1.0) |> max(0.0)
    "#{:erlang.float_to_binary(clamped * 100.0, decimals: decimals)}%"
  end

  @doc """
  Returns a relative timestamp like "12s ago", "3m ago", "2h ago".
  Accepts a DateTime, NaiveDateTime, integer (unix seconds), or nil.
  """
  @spec relative_time(DateTime.t() | NaiveDateTime.t() | integer() | nil) :: String.t()
  def relative_time(nil), do: "never"

  def relative_time(%DateTime{} = dt) do
    relative_seconds(DateTime.diff(DateTime.utc_now(), dt))
  end

  def relative_time(%NaiveDateTime{} = ndt) do
    now = NaiveDateTime.utc_now()
    relative_seconds(NaiveDateTime.diff(now, ndt))
  end

  def relative_time(unix) when is_integer(unix) do
    now = System.os_time(:second)
    relative_seconds(now - unix)
  end

  def relative_time(_), do: "—"

  defp relative_seconds(secs) when secs < 0, do: "in the future"
  defp relative_seconds(secs) when secs < 60, do: "#{secs}s ago"
  defp relative_seconds(secs) when secs < 3600, do: "#{div(secs, 60)}m ago"
  defp relative_seconds(secs) when secs < 86_400, do: "#{div(secs, 3600)}h ago"
  defp relative_seconds(secs), do: "#{div(secs, 86_400)}d ago"
end
