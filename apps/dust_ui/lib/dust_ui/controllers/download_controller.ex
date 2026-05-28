defmodule Dust.Ui.DownloadController do
  @moduledoc """
  Streams a file out of the Dust network into the HTTP response.

  Mirrors `Dust.Api.Handlers.FsHandler.download/2`: send chunked headers
  first, then call `Dust.Daemon.FileSystem.download_stream/2` with a
  `write_fn` that pipes each iodata into `Plug.Conn.chunk/2`. If decoding
  fails after the first chunk is sent we cannot change status; we just
  close the response and clients reject the body via size/checksum.
  """
  use Dust.Ui, :controller

  def show(conn, %{"file_id" => file_id}) do
    case Dust.Mesh.FileSystem.stat(file_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> text("File not found")

      meta ->
        filename = Map.get(meta, :name, file_id)
        mime = Map.get(meta, :mime) || "application/octet-stream"

        conn =
          conn
          |> put_resp_content_type(mime)
          |> put_resp_header(
            "content-disposition",
            ~s(attachment; filename="#{sanitize(filename)}")
          )
          |> send_chunked(200)

        case Dust.Daemon.FileSystem.download_stream(file_id, fn iodata ->
               case Plug.Conn.chunk(conn, iodata) do
                 {:ok, _conn} -> :ok
                 {:error, _} = err -> err
               end
             end) do
          :ok -> conn
          {:error, _reason} -> conn
        end
    end
  end

  defp sanitize(name) when is_binary(name) do
    name
    |> String.replace(~r/[\r\n"\\]/, "")
    |> String.slice(0, 255)
  end

  defp sanitize(_), do: "download"
end
