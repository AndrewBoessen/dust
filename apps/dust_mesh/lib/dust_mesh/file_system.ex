defmodule Dust.Mesh.FileSystem.DirMap do
  @moduledoc """
  Distributed shared map for directory entries.

  Keys are UUID strings identifying a directory. Values are DirMap structs with
  `:name`, `:dirs` (MapSet), `:files` (MapSet), and `:created_at`.
  """

  use Dust.Mesh.SharedMap

  @enforce_keys [:name, :dirs, :files, :created_at]
  defstruct [:name, :dirs, :files, :created_at]

  @type t :: %__MODULE__{
          name: String.t(),
          dirs: MapSet.t(Dust.Mesh.FileSystem.uuid()),
          files: MapSet.t(Dust.Mesh.FileSystem.uuid()),
          created_at: DateTime.t()
        }

  @spec put(String.t(), map() | t()) :: :ok | {:error, :crdt_unavailable}
  def put(id, entry), do: crdt_put(id, entry)

  @spec get(String.t()) :: map() | nil
  def get(id), do: crdt_get(id)

  @spec delete(String.t()) :: :ok | {:error, :crdt_unavailable}
  def delete(id), do: crdt_delete(id)

  @spec all() :: map()
  def all, do: crdt_to_map()
end

defmodule Dust.Mesh.FileSystem.FileMap do
  @moduledoc """
  Distributed shared map for file metadata.

  Keys are UUID strings identifying a file. Values are FileMap structs
  for metadata with `:created_at` and `:name` always present. Directory
  membership is tracked entirely in `DirMap`.
  """

  use Dust.Mesh.SharedMap

  @enforce_keys [:name, :created_at]
  defstruct [:name, :mime, :size, :checksum, :created_at]

  @type t :: %__MODULE__{
          name: String.t(),
          mime: String.t() | nil,
          size: non_neg_integer() | nil,
          checksum: String.t() | nil,
          created_at: DateTime.t()
        }

  @spec put(String.t(), map() | t()) :: :ok | {:error, :crdt_unavailable}
  def put(id, metadata), do: crdt_put(id, metadata)

  @spec get(String.t()) :: map() | nil
  def get(id), do: crdt_get(id)

  @spec delete(String.t()) :: :ok | {:error, :crdt_unavailable}
  def delete(id), do: crdt_delete(id)

  @spec all() :: map()
  def all, do: crdt_to_map()
end

defmodule Dust.Mesh.FileSystem do
  @moduledoc """
  A distributed file system built on top of `Dust.Mesh.SharedMap`.

  The structure uses two separate CRDT-backed shared maps:

    - `DirMap`  — stores directory entries keyed by UUID string.
                  Each entry holds the directory name, a MapSet of child
                  directory UUIDs, and a MapSet of child file UUIDs.

    - `FileMap` — stores file metadata keyed by UUID string.
                  Purely a flat key → metadata store; directory membership
                  is tracked entirely in `DirMap`.

  Both maps are AWLWWMap CRDTs that sync automatically across all
  connected nodes via DeltaCrdt.
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
        dirs: MapSet.new(),
        files: MapSet.new(),
        created_at: DateTime.utc_now()
      }

      case DirMap.put(id, entry) do
        {:error, :crdt_unavailable} ->
          {:error, :crdt_unavailable}

        :ok ->
          if parent_id do
            update_dir!(parent_id, fn parent ->
              %{parent | dirs: MapSet.put(parent.dirs, id)}
            end)
          end

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

      entry ->
        child_dirs =
          entry.dirs
          |> Enum.map(fn id ->
            case DirMap.get(id) do
              nil -> nil
              d -> Map.take(d, [:name, :created_at]) |> Map.put(:id, id)
            end
          end)
          |> Enum.reject(&is_nil/1)

        child_files =
          entry.files
          |> Enum.map(fn id ->
            case FileMap.get(id) do
              nil -> nil
              f -> Map.put(f, :id, id)
            end
          end)
          |> Enum.reject(&is_nil/1)

        %{dirs: child_dirs, files: child_files}
    end
  end

  @doc "Renames a directory in-place (does not move it)."
  @spec rename_dir(uuid(), String.t()) :: :ok | {:error, :not_found}
  def rename_dir(dir_id, new_name) when is_binary(dir_id) and is_binary(new_name) do
    update_dir(dir_id, fn entry -> %{entry | name: new_name} end)
  end

  @doc """
  Removes an empty directory from its parent.

  Returns `{:error, :not_empty}` if the directory still contains children,
  encouraging callers to remove contents first.
  """
  @spec rmdir(uuid(), uuid() | nil) :: :ok | {:error, :not_found | :not_empty | :crdt_unavailable}
  def rmdir(dir_id, parent_id) when is_binary(dir_id) do
    case DirMap.get(dir_id) do
      nil ->
        {:error, :not_found}

      entry ->
        if MapSet.size(entry.dirs) > 0 or MapSet.size(entry.files) > 0 do
          {:error, :not_empty}
        else
          case DirMap.delete(dir_id) do
            {:error, :crdt_unavailable} ->
              {:error, :crdt_unavailable}

            :ok ->
              if parent_id do
                update_dir!(parent_id, fn parent ->
                  %{parent | dirs: MapSet.delete(parent.dirs, dir_id)}
                end)
              end

              :ok
          end
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
          |> Map.put(:created_at, DateTime.utc_now())

        file = struct(FileMap, file_attrs)

        case FileMap.put(id, file) do
          {:error, :crdt_unavailable} ->
            {:error, :crdt_unavailable}

          :ok ->
            update_dir!(dir_id, fn entry ->
              %{entry | files: MapSet.put(entry.files, id)}
            end)

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
  Moves a file from `source_dir_id` to `dest_dir_id`.

  The file metadata is unchanged; only the directory membership sets are
  updated. If unlinking from the source succeeds but linking to the
  destination fails, the file is re-linked to the source to prevent orphans.
  """
  @spec mv_file(uuid(), uuid(), uuid()) :: :ok | {:error, :not_found}
  def mv_file(file_id, source_dir_id, dest_dir_id)
      when is_binary(file_id) and is_binary(source_dir_id) and is_binary(dest_dir_id) do
    with %{} <- FileMap.get(file_id),
         %{} <- DirMap.get(source_dir_id),
         %{} <- DirMap.get(dest_dir_id) do
      update_dir!(source_dir_id, fn entry ->
        %{entry | files: MapSet.delete(entry.files, file_id)}
      end)

      case update_dir(dest_dir_id, fn entry ->
             %{entry | files: MapSet.put(entry.files, file_id)}
           end) do
        :ok ->
          :ok

        {:error, :not_found} ->
          Logger.warning(
            "FileSystem.mv_file: dest dir #{dest_dir_id} vanished during move, rolling back"
          )

          update_dir!(source_dir_id, fn entry ->
            %{entry | files: MapSet.put(entry.files, file_id)}
          end)

          {:error, :not_found}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Deletes a file and removes it from its parent directory."
  @spec rm_file(uuid(), uuid()) :: :ok | {:error, :not_found | :crdt_unavailable}
  def rm_file(file_id, dir_id) when is_binary(file_id) and is_binary(dir_id) do
    case FileMap.get(file_id) do
      nil ->
        {:error, :not_found}

      _meta ->
        case FileMap.delete(file_id) do
          {:error, :crdt_unavailable} ->
            {:error, :crdt_unavailable}

          :ok ->
            update_dir!(dir_id, fn entry ->
              %{entry | files: MapSet.delete(entry.files, file_id)}
            end)

            :ok
        end
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

  @spec update_dir(uuid(), (dir_entry() -> dir_entry())) ::
          :ok | {:error, :not_found | :crdt_unavailable}
  defp update_dir(dir_id, fun) do
    case DirMap.get(dir_id) do
      nil ->
        {:error, :not_found}

      entry ->
        case DirMap.put(dir_id, fun.(entry)) do
          {:error, :crdt_unavailable} -> {:error, :crdt_unavailable}
          :ok -> :ok
        end
    end
  end

  @doc false
  @spec update_dir!(uuid(), (dir_entry() -> dir_entry())) :: :ok
  defp update_dir!(dir_id, fun) do
    case update_dir(dir_id, fun) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Logger.warning("FileSystem: directory #{dir_id} vanished during update (TOCTOU race)")
        :ok
    end
  end

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
