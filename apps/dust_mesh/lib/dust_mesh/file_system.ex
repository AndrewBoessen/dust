defmodule Dust.Mesh.FileSystem.DirMap do
  @moduledoc """
  Distributed shared map for directory entries.

  Keys are UUID strings identifying a directory. Values are DirMap structs with
  `:name`, `:parent_id`, and `:created_at`.
  """

  use Dust.Mesh.SharedMap

  @enforce_keys [:name, :parent_id, :created_at]
  defstruct [:name, :parent_id, :created_at]

  @type t :: %__MODULE__{
          name: String.t(),
          parent_id: Dust.Mesh.FileSystem.uuid() | nil,
          created_at: DateTime.t()
        }

  @doc "Stores a directory entry under the given `id`."
  @spec put(String.t(), map() | t()) :: :ok | {:error, :crdt_unavailable}
  def put(id, entry), do: crdt_put(id, entry)

  @doc "Returns the directory entry for `id`, or `nil` if not found."
  @spec get(String.t()) :: map() | nil
  def get(id), do: crdt_get(id)

  @doc "Deletes the directory entry for `id`."
  @spec delete(String.t()) :: :ok | {:error, :crdt_unavailable}
  def delete(id), do: crdt_delete(id)

  @doc "Returns all directory entries as a plain map."
  @spec all() :: map()
  def all, do: crdt_to_map()
end

defmodule Dust.Mesh.FileSystem.FileMap do
  @moduledoc """
  Distributed shared map for file metadata.

  Keys are UUID strings identifying a file. Values are FileMap structs
  for metadata with `:created_at`, `:name`, and `:dir_id` always present.
  """

  use Dust.Mesh.SharedMap

  @enforce_keys [:name, :dir_id, :created_at]
  defstruct [:name, :dir_id, :mime, :size, :checksum, :created_at]

  @type t :: %__MODULE__{
          name: String.t(),
          dir_id: Dust.Mesh.FileSystem.uuid(),
          mime: String.t() | nil,
          size: non_neg_integer() | nil,
          checksum: String.t() | nil,
          created_at: DateTime.t()
        }

  @doc "Stores file metadata under the given `id`."
  @spec put(String.t(), map() | t()) :: :ok | {:error, :crdt_unavailable}
  def put(id, metadata), do: crdt_put(id, metadata)

  @doc "Returns file metadata for `id`, or `nil` if not found."
  @spec get(String.t()) :: map() | nil
  def get(id), do: crdt_get(id)

  @doc "Deletes the file metadata for `id`."
  @spec delete(String.t()) :: :ok | {:error, :crdt_unavailable}
  def delete(id), do: crdt_delete(id)

  @doc "Returns all file metadata as a plain map."
  @spec all() :: map()
  def all, do: crdt_to_map()
end

defmodule Dust.Mesh.FileSystem do
  @moduledoc """
  A distributed file system built on top of `Dust.Mesh.SharedMap`.

  The structure uses two separate CRDT-backed shared maps:

    - `DirMap`  — stores directory entries keyed by UUID string.
                  Each entry holds the directory name, parent directory
                  UUID (or nil), and creation timestamp.

    - `FileMap` — stores file metadata keyed by UUID string.
                  Includes a dir_id to reference the directory it 
                  currently sits in.

  Because parents do not hold vectors/lists of children, concurrent
  modifications (adding two files to a dir) resolve purely via independent
  Last-Writer-Wins map keys, avoiding all TOCTOU data-loss.
  """

  alias Dust.Mesh.FileSystem.{DirMap, FileMap}

  require Logger

  # ── Types ───────────────────────────────────────────────────────────────────

  @type uuid :: String.t()

  @type dir_entry :: DirMap.t()

  @type file_metadata :: FileMap.t()

  # ── Directory API ───────────────────────────────────────────────────────────

  @doc """
  Creates a new directory under `parent_id`.

  Pass `nil` as `parent_id` to create a root-level directory (no parent link
  is stored; you are responsible for tracking the root UUID yourself, e.g. in
  application config or a dedicated singleton key).

  Returns `{:ok, new_dir_id}` or `{:error, :parent_not_found}` if a non-nil
  parent ID does not exist.
  """
  @spec mkdir(uuid() | nil, String.t()) ::
          {:ok, uuid()} | {:error, :parent_not_found | :crdt_unavailable}
  def mkdir(parent_id, name) when is_binary(name) do
    if parent_id != nil and DirMap.get(parent_id) == nil do
      {:error, :parent_not_found}
    else
      id = generate_uuid()

      entry = %DirMap{
        name: name,
        parent_id: parent_id,
        created_at: DateTime.utc_now()
      }

      case DirMap.put(id, entry) do
        {:error, :crdt_unavailable} ->
          {:error, :crdt_unavailable}

        :ok ->
          {:ok, id}
      end
    end
  end

  @doc "Returns the raw directory entry for `dir_id`, or `nil` if not found."
  @spec get_dir(uuid()) :: dir_entry() | nil
  def get_dir(dir_id) when is_binary(dir_id), do: DirMap.get(dir_id)

  @doc """
  Lists the immediate children of a directory.

  Returns a map with two keys:

    - `:dirs`  — list of `%{id, name, created_at}` for child directories
    - `:files` — list of `%{id, name, ...metadata}` for child files
  """
  @spec ls(uuid()) :: %{dirs: [map()], files: [map()]} | {:error, :not_found}
  def ls(dir_id) when is_binary(dir_id) do
    case DirMap.get(dir_id) do
      nil ->
        {:error, :not_found}

      _entry ->
        child_dirs =
          DirMap.all()
          |> Enum.filter(fn {_id, dir} -> dir.parent_id == dir_id end)
          |> Enum.map(fn {id, dir} ->
            Map.take(dir, [:name, :created_at]) |> Map.put(:id, id)
          end)

        child_files =
          FileMap.all()
          |> Enum.filter(fn {_id, file} -> file.dir_id == dir_id end)
          |> Enum.map(fn {id, file} ->
            Map.put(file, :id, id)
          end)

        %{dirs: child_dirs, files: child_files}
    end
  end

  @doc "Renames a directory in-place (does not move it)."
  @spec rename_dir(uuid(), String.t()) :: :ok | {:error, :not_found | :crdt_unavailable}
  def rename_dir(dir_id, new_name) when is_binary(dir_id) and is_binary(new_name) do
    case DirMap.get(dir_id) do
      nil ->
        {:error, :not_found}

      entry ->
        case DirMap.put(dir_id, %{entry | name: new_name}) do
          {:error, :crdt_unavailable} -> {:error, :crdt_unavailable}
          :ok -> :ok
        end
    end
  end

  @doc """
  Removes an empty directory.

  Returns `{:error, :not_empty}` if the directory still contains children,
  encouraging callers to remove contents first. (Accepts parent_id for legacy 
  API compliance, but unneeded).
  """
  @spec rmdir(uuid(), uuid() | nil) :: :ok | {:error, :not_found | :not_empty | :crdt_unavailable}
  def rmdir(dir_id, _parent_id \\ nil) when is_binary(dir_id) do
    case DirMap.get(dir_id) do
      nil ->
        {:error, :not_found}

      _entry ->
        has_dirs = DirMap.all() |> Enum.any?(fn {_id, dir} -> dir.parent_id == dir_id end)
        has_files = FileMap.all() |> Enum.any?(fn {_id, file} -> file.dir_id == dir_id end)

        if has_dirs or has_files do
          {:error, :not_empty}
        else
          DirMap.delete(dir_id)
        end
    end
  end

  # ── File API ────────────────────────────────────────────────────────────────

  @doc """
  Adds a file to a directory.

  `metadata` is any map of extra fields (size, mime type, checksum, etc.).
  The `:name` and `:created_at` fields are managed automatically.

  Returns `{:ok, file_id}`.
  """
  @spec put_file(uuid(), String.t(), map()) ::
          {:ok, uuid()} | {:error, :dir_not_found | :crdt_unavailable}
  def put_file(dir_id, name, metadata \\ %{})

  def put_file(dir_id, name, metadata) when is_binary(dir_id) and is_binary(name) do
    case DirMap.get(dir_id) do
      nil ->
        {:error, :dir_not_found}

      _entry ->
        id = generate_uuid()

        file_attrs =
          metadata
          |> Map.put(:name, name)
          |> Map.put(:dir_id, dir_id)
          |> Map.put(:created_at, DateTime.utc_now())

        file = struct(FileMap, file_attrs)

        case FileMap.put(id, file) do
          {:error, :crdt_unavailable} ->
            {:error, :crdt_unavailable}

          :ok ->
            {:ok, id}
        end
    end
  end

  @doc "Returns full metadata for a file, including its `id`, or `nil` if not found."
  @spec stat(uuid()) :: map() | nil
  def stat(file_id) when is_binary(file_id) do
    case FileMap.get(file_id) do
      nil -> nil
      meta -> Map.put(meta, :id, file_id)
    end
  end

  @doc "Updates file metadata by merging `updates` into the existing metadata map."
  @spec update_file(uuid(), map()) :: :ok | {:error, :not_found | :crdt_unavailable}
  def update_file(file_id, updates) when is_binary(file_id) and is_map(updates) do
    case FileMap.get(file_id) do
      nil ->
        {:error, :not_found}

      existing ->
        case FileMap.put(file_id, Map.merge(existing, updates)) do
          {:error, :crdt_unavailable} -> {:error, :crdt_unavailable}
          :ok -> :ok
        end
    end
  end

  @doc """
  Moves a file to `dest_dir_id`. (Accepts source_dir_id for legacy API compliance).
  """
  @spec mv_file(uuid(), uuid(), uuid()) :: :ok | {:error, :not_found}
  def mv_file(file_id, _source_dir_id \\ nil, dest_dir_id)
      when is_binary(file_id) and is_binary(dest_dir_id) do
    with %{} <- FileMap.get(file_id),
         %{} <- DirMap.get(dest_dir_id) do
      update_file(file_id, %{dir_id: dest_dir_id})
      :ok
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Deletes a file entirely. (Accepts dir_id for legacy API compliance)."
  @spec rm_file(uuid(), uuid() | nil) :: :ok | {:error, :not_found | :crdt_unavailable}
  def rm_file(file_id, _dir_id \\ nil) when is_binary(file_id) do
    case FileMap.get(file_id) do
      nil ->
        {:error, :not_found}

      _meta ->
        FileMap.delete(file_id)
    end
  end

  # ── Cluster-wide introspection ──────────────────────────────────────────────

  @doc "Returns the full directory map across the cluster as a plain Elixir map."
  @spec all_dirs() :: %{uuid() => dir_entry()}
  def all_dirs, do: DirMap.all()

  @doc "Returns the full file map across the cluster as a plain Elixir map."
  @spec all_files() :: %{uuid() => file_metadata()}
  def all_files, do: FileMap.all()

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec generate_uuid() :: uuid()
  defp generate_uuid do
    <<a::48, _v::4, b::12, _r::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, rest::binary>> = hex
      "#{p1}-#{p2}-#{p3}-#{p4}-#{rest}"
    end)
  end
end
