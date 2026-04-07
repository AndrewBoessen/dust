defmodule Dust.Daemon.FileSystem do
  @moduledoc """
  Public high-level facade for file operations across the Dust network.

  Orchestrates cryptography (Core), indexing (Mesh), persistence (Storage),
  and peer distribution (Bridge).
  """

  alias Dust.Core.{Crypto, Packer, Unpacker, ErasureCoding}
  alias Dust.Mesh.{FileSystem, Manifest}
  alias Dust.Storage

  @doc """
  Uploads and distributes a local file across the Dust storage network.

  This function orchestrates the entire upload pipeline:
    1. Initializes an entry in the virtual file system.
    2. Streams the file from disk, dividing it into encrypted chunks.
    3. Applies erasure-coding to split each chunk into shards.
    4. Distributes and stores the encoded shards into the storage engine.
    5. Commits the final chunk metadata layout to the distributed manifest.

  If an unrecoverable fault occurs at any point during chunking or writing to the manifest,
  an internal cleanup routine is executed to roll back partial filesystem entries and
  purge any orphaned shards from the cluster to prevent space leaks.
  """
  @spec upload(Path.t(), FileSystem.uuid(), String.t()) ::
          {:ok, FileSystem.uuid()}
          | {:error, File.posix() | :file_store_failed | :crdt_unavailable | :dir_not_found}
  def upload(local_file_path, dest_dir_id, file_name) do
    # Stream file chunks
    case Packer.process_file_stream(local_file_path) do
      {:ok, file_meta, stream} ->
        # Add file to mesh filesystem
        case FileSystem.put_file(dest_dir_id, file_name, file_meta) do
          {:ok, file_uuid} ->
            chunk_meta_list =
              Enum.reduce_while(stream, {:ok, []}, fn {chunk_meta, binary}, {:ok, acc} ->
                %Crypto.ChunkMeta{hash: chunk_hash} = chunk_meta
                {:ok, shards} = ErasureCoding.encode(binary)
                # store shards in db and reduce to shard list
                shard_list =
                  shards
                  |> Enum.with_index()
                  |> Enum.reduce_while({:ok, []}, fn {shard_binary, shard_index},
                                                     {:ok, shard_acc} ->
                    case Storage.put_shard(chunk_hash, shard_index, shard_binary) do
                      :ok -> {:cont, {:ok, [{shard_index, node()} | shard_acc]}}
                      {:error, _reason} -> {:halt, {:error, :shard_storage_failed}}
                    end
                  end)

                # write shards to manifest
                case shard_list do
                  {:ok, shard_data} ->
                    case Manifest.store_shards(chunk_hash, shard_data) do
                      :ok ->
                        {:cont, {:ok, [chunk_meta | acc]}}

                      {:error, :crdt_unavailable} ->
                        {:halt, {:error, :crdt_unavailable, [chunk_meta | acc]}}
                    end

                  {:error, :shard_storage_failed} ->
                    {:halt, {:error, :chunk_store_failed, [chunk_meta | acc]}}
                end
              end)

            # write file to manifest
            case chunk_meta_list do
              {:ok, meta_list_reversed} ->
                meta_list = Enum.reverse(meta_list_reversed)

                case Manifest.store_file_stream(
                       file_uuid,
                       file_meta,
                       meta_list
                     ) do
                  :ok ->
                    {:ok, file_uuid}

                  {:error, :crdt_unavailable} = crdt_error ->
                    cleanup_upload(file_uuid, meta_list)
                    crdt_error
                end

              # failed to store in database
              {:error, :chunk_store_failed, attempted_meta_list} ->
                cleanup_upload(file_uuid, attempted_meta_list)
                {:error, :file_store_failed}

              # failed to write manifest
              {:error, :crdt_unavailable, attempted_meta_list} ->
                cleanup_upload(file_uuid, attempted_meta_list)
                {:error, :crdt_unavailable}
            end

          # failed to add to mesh filesystem
          {:error, reason} ->
            {:error, reason}
        end

      # failed to open file
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_upload(file_uuid, meta_list) do
    # purge the orphan filesystem entry
    Dust.Mesh.FileSystem.rm_file(file_uuid)

    # delete all tracked shards off disk and out of manifest
    Enum.each(meta_list, fn %Crypto.ChunkMeta{hash: chunk_hash} ->
      Storage.delete_chunk_shards(chunk_hash, 6)
      Dust.Mesh.Manifest.ShardMap.delete_shards(chunk_hash, 6)
    end)
  end

  @doc """
  Downloads a file from the Dust network.
  """
  def download(file_uuid, local_dest_path) do
    # Orchestrate fetching shards, erasure decoding, decryption, and reconstructing
    {:error, :not_implemented}
  end
end
