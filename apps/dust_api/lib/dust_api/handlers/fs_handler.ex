defmodule Dust.Api.Handlers.FsHandler do
  @moduledoc """
  Handles file system operations:

    - `GET    /api/v1/fs/ls/:dir_id`  — list directory contents
    - `POST   /api/v1/fs/mkdir`       — create a directory
    - `POST   /api/v1/fs/upload`      — upload a file (multipart or JSON)
    - `POST   /api/v1/fs/download`    — download a file to a local path
    - `DELETE /api/v1/fs/rm/:id`      — delete a file or directory
  """

  import Plug.Conn

  alias Dust.Mesh.FileSystem

  @doc "List the contents of a directory."
  @spec list(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def list(conn, dir_id) do
    case FileSystem.ls(dir_id) do
      %{dirs: dirs, files: files} ->
        formatted_dirs =
          Enum.map(dirs, fn entry ->
            Map.take(entry, [:id, :name, :created_at])
            |> Enum.into(%{}, fn {k, v} -> {k, to_string(v)} end)
          end)

        formatted_files =
          Enum.map(files, fn entry ->
            serialize_meta(entry)
          end)

        json_response(conn, 200, %{dir_id: dir_id, dirs: formatted_dirs, files: formatted_files})

      {:error, :not_found} ->
        json_response(conn, 404, %{error: "directory_not_found"})

      {:error, reason} ->
        json_response(conn, 500, %{error: inspect(reason)})
    end
  end

  @doc "Create a new directory."
  @spec mkdir(Plug.Conn.t()) :: Plug.Conn.t()
  def mkdir(conn) do
    case conn.body_params do
      %{"parent_id" => parent_id, "name" => name} ->
        case FileSystem.mkdir(parent_id, name) do
          {:ok, dir_id} ->
            json_response(conn, 201, %{dir_id: dir_id})

          {:error, reason} ->
            json_response(conn, 400, %{error: inspect(reason)})
        end

      _ ->
        json_response(conn, 400, %{
          error: "missing_fields",
          message: "'parent_id' and 'name' are required"
        })
    end
  end

  @doc "Upload a file."
  @spec upload(Plug.Conn.t()) :: Plug.Conn.t()
  def upload(conn) do
    case conn.body_params do
      %{"local_path" => local_path, "dir_id" => dir_id, "file_name" => file_name} ->
        case Dust.Daemon.FileSystem.upload(local_path, dir_id, file_name) do
          {:ok, file_uuid} ->
            json_response(conn, 201, %{file_id: file_uuid})

          {:error, reason} ->
            json_response(conn, 400, %{error: inspect(reason)})
        end

      _ ->
        json_response(conn, 400, %{
          error: "missing_fields",
          message: "'local_path', 'dir_id', and 'file_name' are required"
        })
    end
  end

  @doc "Download a file to a local path."
  @spec download(Plug.Conn.t()) :: Plug.Conn.t()
  def download(conn) do
    case conn.body_params do
      %{"file_id" => file_id, "dest_path" => dest_path} ->
        case Dust.Daemon.FileSystem.download(file_id, dest_path) do
          {:ok, path} ->
            json_response(conn, 200, %{path: path})

          {:error, reason} ->
            json_response(conn, 400, %{error: inspect(reason)})
        end

      _ ->
        json_response(conn, 400, %{
          error: "missing_fields",
          message: "'file_id' and 'dest_path' are required"
        })
    end
  end

  @doc "Remove a file or directory."
  @spec remove(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def remove(conn, id) do
    # Try file first, then directory
    case FileSystem.rm_file(id) do
      :ok ->
        json_response(conn, 200, %{status: "deleted", id: id})

      {:error, :not_found} ->
        case FileSystem.rmdir(id) do
          :ok ->
            json_response(conn, 200, %{status: "deleted", id: id})

          {:error, reason} ->
            json_response(conn, 400, %{error: inspect(reason)})
        end

      {:error, reason} ->
        json_response(conn, 400, %{error: inspect(reason)})
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp serialize_meta(meta) when is_map(meta) do
    meta
    |> Map.take([:type, :size, :mime, :checksum, :created_at, :updated_at])
    |> Enum.into(%{}, fn {k, v} -> {k, to_string(v)} end)
  end

  defp serialize_meta(_), do: %{}

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
