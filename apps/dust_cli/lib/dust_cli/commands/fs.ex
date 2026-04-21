defmodule Dust.CLI.Commands.Fs do
  @moduledoc """
  Handles file system operations using path-based addressing:

      dustctl ls [PATH]
      dustctl mkdir PATH
      dustctl upload LOCAL_FILE [REMOTE_PATH]
      dustctl download REMOTE_PATH DEST
      dustctl rm PATH
      dustctl stat PATH
  """

  alias Dust.CLI.{Client, Formatter, Progress}

  # ── ls ─────────────────────────────────────────────────────────────────

  def ls(config, args) do
    require_unlocked!(config)
    {opts, rest, _} = OptionParser.parse(args, strict: [long: :boolean], aliases: [l: :long])

    path = List.first(rest, "/")

    with :ok <- validate_path(path),
         {:ok, dir_id} <- resolve_dir_path(config, path) do
      case Client.get(config, "/api/v1/fs/ls/#{dir_id}") do
        {200, {:ok, body}} ->
          display_listing(body, Keyword.get(opts, :long, false))
          0

        {404, _} ->
          Formatter.error("Directory not found: #{path}")
          1

        {:error, {:failed_connect, _}} ->
          Formatter.daemon_unreachable()
          1

        other ->
          Formatter.error("Unexpected response: #{inspect(other)}")
          1
      end
    else
      {:error, :no_root} ->
        Formatter.error("No root directory found.")
        Formatter.info("Run: dustctl init")
        1

      {:error, {:not_found, segment}} ->
        Formatter.error("Path not found: #{path} (no entry named '#{segment}')")
        1

      {:error, {:invalid_path, reason}} ->
        Formatter.error("Invalid path: #{reason}")
        1

      {:error, _} ->
        Formatter.error("Failed to resolve path: #{path}")
        1
    end
  end

  defp display_listing(body, long) do
    dirs = body["dirs"] || []
    files = body["files"] || []

    if dirs == [] and files == [] do
      Formatter.dim("(empty directory)")
    else
      if long do
        headers = ["Type", "Name", "ID", "Size"]

        dir_rows =
          Enum.map(dirs, fn d ->
            ["dir", d["name"] || "?", d["id"] || "?", "—"]
          end)

        file_rows =
          Enum.map(files, fn f ->
            ["file", f["name"] || "?", f["id"] || "?", f["size"] || "—"]
          end)

        IO.puts("")
        Formatter.table(headers, dir_rows ++ file_rows)
      else
        Enum.each(dirs, fn d ->
          IO.puts("  #{d["name"] || d["id"]}/")
        end)

        Enum.each(files, fn f ->
          IO.puts("  #{f["name"] || f["id"]}")
        end)
      end
    end

    IO.puts("")
    Formatter.dim("#{length(dirs)} directories, #{length(files)} files")
  end

  # ── mkdir ──────────────────────────────────────────────────────────────

  def mkdir(config, args) do
    require_unlocked!(config)
    {_opts, rest, _} = OptionParser.parse(args, strict: [])

    case rest do
      [path | _] ->
        do_mkdir(config, path)

      [] ->
        Formatter.error("Missing path")
        IO.puts("  Usage: dustctl mkdir PATH")
        IO.puts("  Example: dustctl mkdir /photos/vacation")
        1
    end
  end

  defp do_mkdir(config, "/") do
    case find_root_dir(config) do
      nil ->
        case Client.post(config, "/api/v1/fs/mkdir", %{parent_id: nil, name: "/"}) do
          {201, {:ok, %{"dir_id" => dir_id}}} ->
            case Client.put(config, "/api/v1/config", %{root_dir_id: dir_id}) do
              {200, _} ->
                Formatter.success("Created root directory (#{dir_id})")
                0

              _ ->
                Formatter.warning("Created root directory but failed to save ID to config")
                0
            end

          {409, {:ok, %{"error" => "root_already_exists"}}} ->
            Formatter.error("Root directory already exists")
            1

          {_, {:ok, %{"error" => reason}}} ->
            Formatter.error("Failed to create root directory: #{reason}")
            1

          {:error, {:failed_connect, _}} ->
            Formatter.daemon_unreachable()
            1

          other ->
            Formatter.error("Unexpected response: #{inspect(other)}")
            1
        end

      _id ->
        Formatter.error("Root directory already exists")
        1
    end
  end

  defp do_mkdir(config, path) do
    with :ok <- validate_path(path) do
      parent_path = Path.dirname(path)
      name = Path.basename(path)

      with {:ok, parent_id} <- resolve_dir_path(config, parent_path) do
        case Client.post(config, "/api/v1/fs/mkdir", %{parent_id: parent_id, name: name}) do
          {201, {:ok, %{"dir_id" => dir_id}}} ->
            Formatter.success("Created directory #{path} (#{dir_id})")
            0

          {409, {:ok, %{"error" => "directory_already_exists"}}} ->
            Formatter.error("Directory already exists: #{path}")
            1

          {_, {:ok, %{"error" => reason}}} ->
            Formatter.error("Failed to create directory: #{reason}")
            1

          {:error, {:failed_connect, _}} ->
            Formatter.daemon_unreachable()
            1

          other ->
            Formatter.error("Unexpected response: #{inspect(other)}")
            1
        end
      else
        {:error, :no_root} ->
          Formatter.error("No root directory found.")
          Formatter.info("Run: dustctl init")
          1

        {:error, {:not_found, segment}} ->
          Formatter.error("Parent path not found: #{parent_path} (no entry named '#{segment}')")
          1

        {:error, _} ->
          Formatter.error("Failed to resolve parent path: #{parent_path}")
          1
      end
    else
      {:error, {:invalid_path, reason}} ->
        Formatter.error("Invalid path: #{reason}")
        1
    end
  end

  # ── upload ─────────────────────────────────────────────────────────────

  def upload(config, args) do
    require_unlocked!(config)
    {opts, rest, _} =
      OptionParser.parse(args, strict: [name: :string], aliases: [n: :name])

    case rest do
      [file_path | rest_args] ->
        expanded = Path.expand(file_path)

        unless File.exists?(expanded) do
          Formatter.error("File not found: #{expanded}")
          return_exit(1)
        end

        remote_path = List.first(rest_args)
        default_name = Keyword.get(opts, :name) || Path.basename(expanded)

        {resolve_result, name} =
          cond do
            remote_path == nil ->
              {get_root_dir_id(config), default_name}

            String.ends_with?(remote_path, "/") ->
              trimmed = String.trim_trailing(remote_path, "/")
              target = if trimmed == "", do: "/", else: trimmed
              {resolve_dir_path(config, target), default_name}

            true ->
              with :ok <- validate_path(remote_path) do
                {resolve_dir_path(config, Path.dirname(remote_path)), Path.basename(remote_path)}
              else
                err -> {err, default_name}
              end
          end

        case resolve_result do
          {:ok, dir_id} ->
            do_upload(config, expanded, dir_id, name)

          {:error, :no_root} ->
            Formatter.error("No root directory found.")
            Formatter.info("Run: dustctl init")
            1

          {:error, {:not_found, segment}} ->
            Formatter.error("Remote path not found (no entry named '#{segment}')")
            1

          {:error, {:invalid_path, reason}} ->
            Formatter.error("Invalid path: #{reason}")
            1

          {:error, _} ->
            Formatter.error("Failed to resolve remote path")
            1
        end

      [] ->
        Formatter.error("Missing file path")
        IO.puts("  Usage: dustctl upload LOCAL_FILE [REMOTE_PATH]")
        IO.puts("  Examples:")
        IO.puts("    dustctl upload photo.jpg /photos/")
        IO.puts("    dustctl upload photo.jpg /photos/renamed.jpg")
        1
    end
  end

  defp do_upload(config, local_path, dir_id, file_name) do
    label = "#{file_name}  #{format_file_size(local_path)}"

    ws =
      case Progress.start(config, label, :upload) do
        {:ok, pid} -> pid
        _ ->
          Formatter.info("Uploading #{label}...")
          nil
      end

    result =
      Task.async(fn ->
        Client.post(config, "/api/v1/fs/upload", %{
          local_path: local_path,
          dir_id: dir_id,
          file_name: file_name
        })
      end)
      |> Task.await(:infinity)

    if ws, do: Progress.stop(ws)

    case result do
      {201, {:ok, %{"file_id" => file_id}}} ->
        Formatter.success("#{file_name} uploaded (#{file_id})")
        0

      {_, {:ok, %{"error" => reason}}} ->
        Formatter.error("Upload failed: #{reason}")
        1

      {:error, {:failed_connect, _}} ->
        Formatter.daemon_unreachable()
        1

      other ->
        Formatter.error("Unexpected response: #{inspect(other)}")
        1
    end
  end

  # ── download ───────────────────────────────────────────────────────────

  def download(config, args) do
    require_unlocked!(config)

    case args do
      [remote_path, dest_path | _] ->
        expanded_dest = Path.expand(dest_path)

        with :ok <- validate_path(remote_path),
             {:ok, file_id} <- resolve_file_path(config, remote_path) do
          do_download(config, file_id, remote_path, expanded_dest)
        else
          {:error, :no_root} ->
            Formatter.error("No root directory found.")
            Formatter.info("Run: dustctl init")
            1

          {:error, {:not_found, segment}} ->
            Formatter.error("Path not found: #{remote_path} (no entry named '#{segment}')")
            1

          {:error, {:invalid_path, reason}} ->
            Formatter.error("Invalid path: #{reason}")
            1

          {:error, _} ->
            Formatter.error("Failed to resolve path: #{remote_path}")
            1
        end

      _ ->
        Formatter.error("Missing arguments")
        IO.puts("  Usage: dustctl download REMOTE_PATH DEST")
        IO.puts("  Example: dustctl download /photos/img.jpg ./local.jpg")
        1
    end
  end

  defp do_download(config, file_id, remote_path, dest_path) do
    label = "#{Path.basename(remote_path)} → #{dest_path}"

    ws =
      case Progress.start(config, label, :download) do
        {:ok, pid} -> pid
        _ ->
          Formatter.info("Downloading #{label}...")
          nil
      end

    result =
      Task.async(fn ->
        Client.post(config, "/api/v1/fs/download", %{
          file_id: file_id,
          dest_path: dest_path
        })
      end)
      |> Task.await(:infinity)

    if ws, do: Progress.stop(ws)

    case result do
      {200, {:ok, %{"path" => path}}} ->
        Formatter.success("Downloaded to #{path}")
        0

      {_, {:ok, %{"error" => reason}}} ->
        Formatter.error("Download failed: #{reason}")
        1

      {:error, {:failed_connect, _}} ->
        Formatter.daemon_unreachable()
        1

      other ->
        Formatter.error("Unexpected response: #{inspect(other)}")
        1
    end
  end

  # ── stat ───────────────────────────────────────────────────────────────

  def stat(config, args) do
    require_unlocked!(config)
    {_opts, rest, _} = OptionParser.parse(args, strict: [])

    case rest do
      [path | _] ->
        with :ok <- validate_path(path),
             {:ok, file_id} <- resolve_file_path(config, path) do
          case Client.get(config, "/api/v1/fs/stat/#{file_id}") do
            {200, {:ok, %{"file" => file}}} ->
              IO.puts("")
              Formatter.kv_box("File Info", [
                {"Name", file["name"] || "—"},
                {"ID", file["id"] || file_id},
                {"MIME", file["mime"] || "—"},
                {"Size", format_size(file["size"])},
                {"Checksum", file["checksum"] || "—"},
                {"Created", file["created_at"] || "—"}
              ])
              IO.puts("")
              0

            {404, _} ->
              Formatter.error("File not found: #{path}")
              1

            {:error, {:failed_connect, _}} ->
              Formatter.daemon_unreachable()
              1

            other ->
              Formatter.error("Unexpected response: #{inspect(other)}")
              1
          end
        else
          {:error, :no_root} ->
            Formatter.error("No root directory found.")
            Formatter.info("Run: dustctl init")
            1

          {:error, {:not_found, segment}} ->
            Formatter.error("Path not found: #{path} (no entry named '#{segment}')")
            1

          {:error, {:invalid_path, reason}} ->
            Formatter.error("Invalid path: #{reason}")
            1

          {:error, _} ->
            Formatter.error("Failed to resolve path: #{path}")
            1
        end

      [] ->
        Formatter.error("Missing path")
        IO.puts("  Usage: dustctl stat PATH")
        IO.puts("  Example: dustctl stat /photos/img.jpg")
        1
    end
  end

  # ── rm ─────────────────────────────────────────────────────────────────

  def rm(config, args) do
    require_unlocked!(config)

    case args do
      [path | _] ->
        with :ok <- validate_path(path),
             {:ok, id} <- resolve_any_path(config, path) do
          case Client.delete(config, "/api/v1/fs/rm/#{id}") do
            {200, {:ok, %{"status" => "deleted"}}} ->
              Formatter.success("Deleted #{path}")
              0

            {_, {:ok, %{"error" => reason}}} ->
              Formatter.error("Delete failed: #{reason}")
              1

            {:error, {:failed_connect, _}} ->
              Formatter.daemon_unreachable()
              1

            other ->
              Formatter.error("Unexpected response: #{inspect(other)}")
              1
          end
        else
          {:error, :no_root} ->
            Formatter.error("No root directory found.")
            Formatter.info("Run: dustctl init")
            1

          {:error, {:not_found, segment}} ->
            Formatter.error("Path not found: #{path} (no entry named '#{segment}')")
            1

          {:error, {:invalid_path, reason}} ->
            Formatter.error("Invalid path: #{reason}")
            1

          {:error, _} ->
            Formatter.error("Failed to resolve path: #{path}")
            1
        end

      [] ->
        Formatter.error("Missing path")
        IO.puts("  Usage: dustctl rm PATH")
        IO.puts("  Example: dustctl rm /photos/vacation")
        1
    end
  end

  # ── Path Resolution ────────────────────────────────────────────────────

  defp validate_path(path) do
    cond do
      not String.starts_with?(path, "/") ->
        {:error, {:invalid_path, "path must be absolute (start with /): #{path}"}}

      String.contains?(path, "//") ->
        {:error, {:invalid_path, "path contains empty segment: #{path}"}}

      Enum.any?(String.split(path, "/"), &(&1 == "..")) ->
        {:error, {:invalid_path, "path must not contain '..': #{path}"}}

      true ->
        :ok
    end
  end

  defp get_root_dir_id(config) do
    case find_root_dir(config) do
      nil -> {:error, :no_root}
      id -> {:ok, id}
    end
  end

  defp resolve_dir_path(config, "/") do
    get_root_dir_id(config)
  end

  defp resolve_dir_path(config, path) do
    segments =
      path
      |> String.trim_leading("/")
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    with {:ok, root_id} <- get_root_dir_id(config) do
      Enum.reduce_while(segments, {:ok, root_id}, fn segment, {:ok, current_id} ->
        case Client.get(config, "/api/v1/fs/ls/#{current_id}") do
          {200, {:ok, body}} ->
            dirs = Map.get(body, "dirs", [])

            case Enum.find(dirs, fn d -> d["name"] == segment end) do
              nil -> {:halt, {:error, {:not_found, segment}}}
              dir -> {:cont, {:ok, dir["id"]}}
            end

          _ ->
            {:halt, {:error, :api_error}}
        end
      end)
    end
  end

  defp resolve_file_path(config, path) do
    dir_path = Path.dirname(path)
    filename = Path.basename(path)

    with {:ok, dir_id} <- resolve_dir_path(config, dir_path) do
      case Client.get(config, "/api/v1/fs/ls/#{dir_id}") do
        {200, {:ok, body}} ->
          files = Map.get(body, "files", [])

          case Enum.find(files, fn f -> f["name"] == filename end) do
            nil -> {:error, {:not_found, filename}}
            file -> {:ok, file["id"]}
          end

        _ ->
          {:error, :api_error}
      end
    end
  end

  defp resolve_any_path(config, path) do
    dir_path = Path.dirname(path)
    name = Path.basename(path)

    with {:ok, parent_id} <- resolve_dir_path(config, dir_path) do
      case Client.get(config, "/api/v1/fs/ls/#{parent_id}") do
        {200, {:ok, body}} ->
          dirs = Map.get(body, "dirs", [])
          files = Map.get(body, "files", [])

          cond do
            dir = Enum.find(dirs, fn d -> d["name"] == name end) ->
              {:ok, dir["id"]}

            file = Enum.find(files, fn f -> f["name"] == name end) ->
              {:ok, file["id"]}

            true ->
              {:error, {:not_found, name}}
          end

        _ ->
          {:error, :api_error}
      end
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp require_unlocked!(config) do
    case Client.get(config, "/api/v1/status") do
      {200, {:ok, %{"key_store" => "unlocked"}}} ->
        :ok

      {200, {:ok, %{"key_store" => "locked"}}} ->
        Formatter.info("Key store is locked. Please unlock it to proceed.")

        case Dust.CLI.Commands.Auth.unlock(config, []) do
          0 -> :ok
          _ -> return_exit(1)
        end

      _ ->
        Formatter.warning("Cannot verify key store status. Is the daemon running?")
        return_exit(1)
    end
  end

  defp find_root_dir(config) do
    case Client.get(config, "/api/v1/config") do
      {200, {:ok, %{"config" => %{"root_dir_id" => id}}}} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp format_size(nil), do: "—"
  defp format_size(""), do: "—"

  defp format_size(size_str) do
    case Integer.parse(size_str) do
      {bytes, _} when bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      {bytes, _} when bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      {bytes, _} when bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      {bytes, _} -> "#{bytes} B"
      :error -> size_str
    end
  end

  defp format_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size >= 1_000_000_000 ->
        "#{Float.round(size / 1_000_000_000, 1)} GB"

      {:ok, %{size: size}} when size >= 1_000_000 ->
        "#{Float.round(size / 1_000_000, 1)} MB"

      {:ok, %{size: size}} when size >= 1_000 ->
        "#{Float.round(size / 1_000, 1)} KB"

      {:ok, %{size: size}} ->
        "#{size} B"

      _ ->
        "unknown"
    end
  end

  defp return_exit(code) do
    System.halt(code)
  end
end
