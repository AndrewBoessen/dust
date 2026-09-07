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

  @archive_mimes ~w(
    application/zip application/x-tar application/gzip application/x-gzip
    application/x-7z-compressed application/vnd.rar application/x-rar-compressed
    application/x-bzip2 application/x-xz
  )

  @spreadsheet_mimes ~w(
    text/csv application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.oasis.opendocument.spreadsheet
  )

  @presentation_mimes ~w(
    application/vnd.ms-powerpoint
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.oasis.opendocument.presentation
  )

  @document_mimes ~w(
    application/pdf application/msword application/rtf
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.oasis.opendocument.text
  )

  @code_mimes ~w(
    application/json application/xml text/xml application/javascript
    application/x-yaml text/yaml
  )

  @doc """
  Maps a MIME type to a Heroicon name (see `Dust.Ui.CoreComponents.icon/1`).

  Falls back to `"hero-document"` for `nil`, `application/octet-stream`, and
  anything unrecognised.
  """
  @spec file_icon(String.t() | nil) :: String.t()
  def file_icon(nil), do: "hero-document"

  def file_icon(mime) when is_binary(mime) do
    cond do
      String.starts_with?(mime, "image/") -> "hero-photo"
      String.starts_with?(mime, "video/") -> "hero-film"
      String.starts_with?(mime, "audio/") -> "hero-musical-note"
      mime in @archive_mimes -> "hero-archive-box"
      mime in @spreadsheet_mimes -> "hero-table-cells"
      mime in @presentation_mimes -> "hero-presentation-chart-bar"
      mime in @document_mimes -> "hero-document-text"
      mime in @code_mimes -> "hero-code-bracket"
      String.starts_with?(mime, "text/") -> "hero-document-text"
      true -> "hero-document"
    end
  end

  def file_icon(_), do: "hero-document"

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
