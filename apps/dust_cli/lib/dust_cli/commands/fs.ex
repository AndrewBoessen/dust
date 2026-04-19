defmodule Dust.CLI.Commands.Fs do
  @moduledoc """
  Handles file system operations:

      dustctl ls [DIR_ID]
      dustctl mkdir NAME [--parent DIR_ID]
      dustctl upload FILE [--dir DIR_ID] [--name NAME]
      dustctl download FILE_ID DEST
      dustctl rm ID
  """

  alias Dust.CLI.{Client, Formatter}

  # ── ls ─────────────────────────────────────────────────────────────────

  def ls(config, args) do
    require_unlocked!(config)
    {opts, rest, _} = OptionParser.parse(args, strict: [long: :boolean], aliases: [l: :long])

    dir_id =
      case rest do
        [id | _] -> id
        [] -> find_root_dir(config)
      end

    if dir_id == nil do
      Formatter.error("No directory specified and no root directory found.")
      Formatter.info("Create a root directory: dustctl mkdir / ")
      return_exit(1)
    end

    case Client.get(config, "/api/v1/fs/ls/#{dir_id}") do
      {200, {:ok, body}} ->
        display_listing(body, Keyword.get(opts, :long, false))
        0

      {404, _} ->
        Formatter.error("Directory not found: #{dir_id}")
        1

      {:error, {:failed_connect, _}} ->
        Formatter.daemon_unreachable()
        1

      other ->
        Formatter.error("Unexpected response: #{inspect(other)}")
        1
    end
  end

  defp display_listing(body, long) do
    dirs = body["dirs"] || []
    files = body["files"] || []

    if dirs == [] and files == [] do
      Formatter.dim("  (empty directory)")
    else
      if long do
        headers = ["Type", "Name", "ID", "Size"]

        dir_rows =
          Enum.map(dirs, fn d ->
            ["📁 dir", d["name"] || "?", d["id"] || "?", "—"]
          end)

        file_rows =
          Enum.map(files, fn f ->
            ["📄 file", f["name"] || "?", f["id"] || "?", f["size"] || "—"]
          end)

        IO.puts("")
        Formatter.table(headers, dir_rows ++ file_rows)
      else
        Enum.each(dirs, fn d ->
          IO.puts("  📁 #{d["name"] || d["id"]}/")
        end)

        Enum.each(files, fn f ->
          IO.puts("  📄 #{f["name"] || f["id"]}")
        end)
      end
    end

    IO.puts("")
    Formatter.dim("  #{length(dirs)} directories, #{length(files)} files")
  end

  # ── mkdir ──────────────────────────────────────────────────────────────

  def mkdir(config, args) do
    require_unlocked!(config)
    {opts, rest, _} = OptionParser.parse(args, strict: [parent: :string], aliases: [p: :parent])

    case rest do
      [name | _] ->
        parent_id = Keyword.get(opts, :parent) || find_root_dir(config)

        case Client.post(config, "/api/v1/fs/mkdir", %{parent_id: parent_id, name: name}) do
          {201, {:ok, %{"dir_id" => dir_id}}} ->
            Formatter.success("Created directory '#{name}' (#{dir_id})")
            0

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

      [] ->
        Formatter.error("Missing directory name")
        IO.puts("  Usage: dustctl mkdir NAME [--parent DIR_ID]")
        1
    end
  end

  # ── upload ─────────────────────────────────────────────────────────────

  def upload(config, args) do
    require_unlocked!(config)
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [dir: :string, name: :string],
        aliases: [d: :dir, n: :name]
      )

    case rest do
      [file_path | _] ->
        expanded = Path.expand(file_path)

        unless File.exists?(expanded) do
          Formatter.error("File not found: #{expanded}")
          return_exit(1)
        end

        dir_id = Keyword.get(opts, :dir) || find_root_dir(config)
        file_name = Keyword.get(opts, :name) || Path.basename(expanded)

        Formatter.info("Uploading #{file_name} (#{format_file_size(expanded)})...")

        case Client.post(config, "/api/v1/fs/upload", %{
               local_path: expanded,
               dir_id: dir_id,
               file_name: file_name
             }) do
          {201, {:ok, %{"file_id" => file_id}}} ->
            Formatter.success("Uploaded #{file_name} → #{file_id}")
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

      [] ->
        Formatter.error("Missing file path")
        IO.puts("  Usage: dustctl upload FILE [--dir DIR_ID] [--name NAME]")
        1
    end
  end

  # ── download ───────────────────────────────────────────────────────────

  def download(config, args) do
    require_unlocked!(config)
    case args do
      [file_id, dest_path | _] ->
        expanded = Path.expand(dest_path)
        Formatter.info("Downloading #{file_id} → #{expanded}...")

        case Client.post(config, "/api/v1/fs/download", %{
               file_id: file_id,
               dest_path: expanded
             }) do
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

      _ ->
        Formatter.error("Missing arguments")
        IO.puts("  Usage: dustctl download FILE_ID DEST_PATH")
        1
    end
  end

  # ── rm ─────────────────────────────────────────────────────────────────

  def rm(config, args) do
    require_unlocked!(config)
    case args do
      [id | _] ->
        case Client.delete(config, "/api/v1/fs/rm/#{id}") do
          {200, {:ok, %{"status" => "deleted"}}} ->
            Formatter.success("Deleted #{id}")
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

      [] ->
        Formatter.error("Missing ID")
        IO.puts("  Usage: dustctl rm ID")
        1
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
    # Try to find the root directory by listing the config
    case Client.get(config, "/api/v1/config") do
      {200, {:ok, %{"config" => %{"root_dir_id" => id}}}} when is_binary(id) and id != "" -> id
      _ -> nil
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
