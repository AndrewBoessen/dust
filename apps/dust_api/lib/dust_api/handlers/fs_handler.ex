defmodule Dust.Api.Handlers.FsHandler do
  @moduledoc """
  Handles file system operations:

    - `GET    /api/v1/fs/ls/:dir_id`           — list directory contents
    - `GET    /api/v1/fs/stat/:file_id`        — get file metadata
    - `POST   /api/v1/fs/mkdir`                — create a directory
    - `POST   /api/v1/fs/upload`               — stream a file in (octet-stream body)
    - `GET    /api/v1/fs/download/:file_id`    — stream a file out (chunked body)
    - `DELETE /api/v1/fs/rm/:id`               — delete a file or directory
  """

  import Plug.Conn

  alias Dust.Mesh.FileSystem
  alias Dust.Utilities.Config

  # Per-iteration body read size when streaming an upload from the request
  # body into the temp file. Plug's default for a single read_body/2 call
  # is 8 MB; we keep that and loop until :ok.
  @upload_read_length 1_000_000
  @upload_read_chunk 8_000_000

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

  @doc "Return metadata for a single file."
  @spec stat(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def stat(conn, file_id) do
    case FileSystem.stat(file_id) do
      nil ->
        json_response(conn, 404, %{error: "file_not_found"})

      meta ->
        file =
          meta
          |> Map.take([:id, :name, :dir_id, :mime, :size, :checksum, :created_at])
          |> Enum.into(%{}, fn {k, v} -> {Atom.to_string(k), to_string(v)} end)

        json_response(conn, 200, %{file: file})
    end
  end

  @doc "Create a new directory."
  @spec mkdir(Plug.Conn.t()) :: Plug.Conn.t()
  def mkdir(conn) do
    case conn.body_params do
      %{"name" => name} = params ->
        parent_id = Map.get(params, "parent_id")

        case FileSystem.mkdir(parent_id, name) do
          {:ok, dir_id} ->
            json_response(conn, 201, %{dir_id: dir_id})

          {:error, :already_exists} ->
            json_response(conn, 409, %{error: "directory_already_exists"})

          {:error, :root_already_exists} ->
            {existing_id, _} =
              FileSystem.all_dirs()
              |> Enum.find(fn {_id, dir} -> dir.parent_id == nil end)

            json_response(conn, 409, %{error: "root_already_exists", dir_id: existing_id})

          {:error, reason} ->
            json_response(conn, 400, %{error: inspect(reason)})
        end

      _ ->
        json_response(conn, 400, %{error: "missing_fields", message: "'name' is required"})
    end
  end

  @doc """
  Stream an upload from the request body into a daemon-owned temp file,
  then hand the temp path to `Dust.Daemon.FileSystem.upload/3`.

  Wire format:
    * `Content-Type: application/octet-stream`
    * `X-Dust-Dir-Id`    header — target directory UUID
    * `X-Dust-File-Name` header — file name within that directory
    * Body — raw file bytes

  The temp file lives under `${persist_dir}/tmp/upload-<rand>.dat` and is
  always deleted before this handler returns. The daemon never reads from
  the caller's filesystem.
  """
  @spec upload(Plug.Conn.t()) :: Plug.Conn.t()
  def upload(conn) do
    with {:ok, dir_id} <- fetch_header(conn, "x-dust-dir-id"),
         {:ok, file_name} <- fetch_header(conn, "x-dust-file-name") do
      temp_path = upload_temp_path()

      try do
        with {:ok, conn} <- stream_body_to_file(conn, temp_path),
             {:ok, file_uuid} <- Dust.Daemon.FileSystem.upload(temp_path, dir_id, file_name) do
          json_response(conn, 201, %{file_id: file_uuid})
        else
          {:error, :body_read_failed, reason} ->
            json_response(conn, 400, %{error: "body_read_failed", reason: inspect(reason)})

          {:error, reason} ->
            json_response(conn, 400, %{error: inspect(reason)})
        end
      after
        _ = File.rm(temp_path)
      end
    else
      {:error, :missing_header, name} ->
        json_response(conn, 400, %{
          error: "missing_header",
          message: "'#{name}' header is required"
        })
    end
  end

  @doc """
  Stream a file out of the Dust network into the HTTP response.

  Bytes are decoded chunk-by-chunk on the daemon side and written into
  the response with `Plug.Conn.chunk/2`, so the daemon never opens a
  file under the caller's path. The CLI receives the body with its own
  permissions.
  """
  @spec download(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def download(conn, file_id) do
    conn =
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_chunked(200)

    case Dust.Daemon.FileSystem.download_stream(file_id, fn iodata ->
           case chunk(conn, iodata) do
             {:ok, _conn} -> :ok
             {:error, _} = err -> err
           end
         end) do
      :ok -> conn
      # Once headers are sent we can't change status — just close the chunked
      # response. Clients see a truncated body which they should reject by
      # length/checksum.
      {:error, _reason} -> conn
    end
  end

  @doc "Move (and optionally rename) a file or directory."
  @spec move(Plug.Conn.t()) :: Plug.Conn.t()
  def move(conn) do
    case conn.body_params do
      %{"id" => id, "type" => type, "dest_dir_id" => dest_dir_id, "new_name" => new_name}
      when type in ["file", "dir"] and is_binary(new_name) and new_name != "" ->
        result =
          case type do
            "file" -> FileSystem.move_file(id, dest_dir_id, new_name)
            "dir" -> FileSystem.move_dir(id, dest_dir_id, new_name)
          end

        case result do
          :ok ->
            json_response(conn, 200, %{status: "moved", id: id})

          {:error, :not_found} ->
            json_response(conn, 404, %{error: "source_not_found"})

          {:error, :dest_not_found} ->
            json_response(conn, 404, %{error: "destination_not_found"})

          {:error, :cannot_move_root} ->
            json_response(conn, 400, %{error: "cannot_move_root"})

          {:error, :cycle} ->
            json_response(conn, 400, %{error: "cycle_detected"})

          {:error, :name_conflict} ->
            json_response(conn, 409, %{error: "name_conflict"})

          {:error, :crdt_unavailable} ->
            json_response(conn, 503, %{error: "crdt_unavailable"})
        end

      %{"type" => type} when type not in ["file", "dir"] ->
        json_response(conn, 400, %{
          error: "invalid_type",
          message: "'type' must be \"file\" or \"dir\""
        })

      %{"new_name" => ""} ->
        json_response(conn, 400, %{error: "invalid_name", message: "'new_name' must not be empty"})

      _ ->
        json_response(conn, 400, %{
          error: "missing_fields",
          message: "'id', 'type', 'dest_dir_id', and 'new_name' are required"
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
    |> Map.take([:id, :name, :size, :mime, :checksum, :created_at])
    |> Enum.into(%{}, fn {k, v} -> {k, to_string(v)} end)
  end

  defp serialize_meta(_), do: %{}

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp fetch_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] when value != "" -> {:ok, value}
      _ -> {:error, :missing_header, name}
    end
  end

  defp upload_temp_path do
    base = Path.join(Config.persist_dir(), "tmp")
    File.mkdir_p!(base)
    rand = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    Path.join(base, "upload-#{rand}.dat")
  end

  defp stream_body_to_file(conn, path) do
    file = File.open!(path, [:write, :binary])

    try do
      do_stream_body(conn, file)
    after
      File.close(file)
    end
  end

  defp do_stream_body(conn, file) do
    case read_body(conn, length: @upload_read_chunk, read_length: @upload_read_length) do
      {:ok, chunk, conn} ->
        IO.binwrite(file, chunk)
        {:ok, conn}

      {:more, chunk, conn} ->
        IO.binwrite(file, chunk)
        do_stream_body(conn, file)

      {:error, reason} ->
        {:error, :body_read_failed, reason}
    end
  end
end
