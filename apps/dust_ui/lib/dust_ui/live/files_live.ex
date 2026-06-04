defmodule Dust.Ui.FilesLive do
  @moduledoc """
  File browser. Lists a directory, supports mkdir / rename / rm and
  drag-drop upload via `Dust.Daemon.FileSystem.upload/3`. Subscribes to
  upload / download progress topics on `Dust.Daemon.Registry`.
  """
  use Dust.Ui, :live_view

  import Dust.Ui.FileTable

  alias Dust.Mesh.FileSystem, as: FS

  @max_upload_size 10 * 1024 * 1024 * 1024
  @max_entries 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      _ = Dust.Daemon.FileSystem.subscribe_upload_progress()
      _ = Dust.Daemon.FileSystem.subscribe_download_progress()
    end

    socket =
      socket
      |> assign(
        page_title: "Files",
        modal: nil,
        rename_target: nil,
        move_target: nil,
        move_candidates: [],
        progress: %{},
        flash_error: nil
      )
      |> allow_upload(:files,
        accept: :any,
        max_entries: @max_entries,
        max_file_size: @max_upload_size,
        auto_upload: false
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case resolve_dir_id(params["dir_id"]) do
      {:ok, dir_id} ->
        {:noreply, socket |> assign(current_dir_id: dir_id) |> refresh_listing()}

      {:error, :no_root} ->
        {:noreply,
         assign(socket,
           current_dir_id: nil,
           entries: %{dirs: [], files: []},
           trail: [],
           needs_root?: true
         )}
    end
  end

  # ── Events ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("upload_validate", _params, socket), do: {:noreply, socket}

  def handle_event("upload_submit", _params, socket) do
    dir_id = socket.assigns.current_dir_id

    consumed =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        case Dust.Daemon.FileSystem.upload(path, dir_id, entry.client_name) do
          {:ok, file_uuid} -> {:ok, file_uuid}
          {:error, reason} -> {:postpone, reason}
        end
      end)

    socket =
      cond do
        consumed == [] ->
          socket

        Enum.all?(consumed, &is_binary/1) ->
          socket |> put_flash(:info, "Uploaded #{length(consumed)} file(s).") |> refresh_listing()

        true ->
          put_flash(socket, :error, "One or more uploads failed.") |> refresh_listing()
      end

    {:noreply, socket}
  end

  def handle_event("open_mkdir", _params, socket),
    do: {:noreply, assign(socket, modal: :mkdir)}

  def handle_event("close_modal", _params, socket),
    do:
      {:noreply,
       assign(socket, modal: nil, rename_target: nil, move_target: nil, move_candidates: [])}

  def handle_event("mkdir_submit", %{"name" => name}, socket) do
    case FS.mkdir(socket.assigns.current_dir_id, String.trim(name)) do
      {:ok, _id} ->
        {:noreply,
         socket |> assign(modal: nil) |> put_flash(:info, "Created.") |> refresh_listing()}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, "A directory with that name already exists.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "mkdir failed: #{inspect(reason)}")}
    end
  end

  def handle_event(
        "open_rename",
        %{"id" => id, "type" => type, "name" => name},
        socket
      ) do
    {:noreply,
     assign(socket, modal: :rename, rename_target: %{id: id, type: type, current_name: name})}
  end

  def handle_event("rename_submit", %{"name" => new_name}, socket) do
    target = socket.assigns.rename_target
    new_name = String.trim(new_name)
    dir_id = socket.assigns.current_dir_id

    result =
      case target.type do
        "file" -> FS.move_file(target.id, dir_id, new_name)
        "dir" -> FS.move_dir(target.id, dir_id, new_name)
      end

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(modal: nil, rename_target: nil)
         |> put_flash(:info, "Renamed.")
         |> refresh_listing()}

      {:error, :name_conflict} ->
        {:noreply, put_flash(socket, :error, "That name is already taken.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rename failed: #{inspect(reason)}")}
    end
  end

  def handle_event(
        "open_move",
        %{"id" => id, "type" => type, "name" => name},
        socket
      ) do
    target = %{id: id, type: type, name: name}
    candidates = move_candidates(target, socket.assigns.current_dir_id)

    {:noreply, assign(socket, modal: :move, move_target: target, move_candidates: candidates)}
  end

  def handle_event("move_submit", %{"dest" => dest_id}, socket) do
    target = socket.assigns.move_target

    result =
      case target.type do
        "file" -> FS.move_file(target.id, dest_id, target.name)
        "dir" -> FS.move_dir(target.id, dest_id, target.name)
      end

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(modal: nil, move_target: nil, move_candidates: [])
         |> put_flash(:info, "Moved.")
         |> refresh_listing()}

      {:error, :name_conflict} ->
        {:noreply,
         put_flash(socket, :error, "A #{target.type} with that name already exists there.")}

      {:error, :cycle} ->
        {:noreply, put_flash(socket, :error, "Cannot move a directory into itself.")}

      {:error, :cannot_move_root} ->
        {:noreply, put_flash(socket, :error, "Cannot move the root directory.")}

      {:error, :dest_not_found} ->
        {:noreply, put_flash(socket, :error, "Destination no longer exists.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Move failed: #{inspect(reason)}")}
    end
  end

  def handle_event("rm", %{"id" => id, "type" => "file"}, socket) do
    case FS.rm_file(id) do
      :ok -> {:noreply, refresh_listing(socket) |> put_flash(:info, "File deleted.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("rm", %{"id" => id, "type" => "dir"}, socket) do
    case FS.rmdir(id) do
      :ok ->
        {:noreply, refresh_listing(socket) |> put_flash(:info, "Directory deleted.")}

      {:error, :not_empty} ->
        {:noreply, put_flash(socket, :error, "Directory is not empty.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("init_root", _params, socket) do
    case FS.mkdir(nil, "root") do
      {:ok, root_id} ->
        _ = Dust.Utilities.Config.put(:root_dir_id, root_id)

        {:noreply,
         push_patch(socket, to: ~p"/files/#{root_id}") |> put_flash(:info, "Root created.")}

      {:error, :root_already_exists} ->
        # Another node already created root — find it and navigate there.
        case existing_root() do
          {:ok, id} -> {:noreply, push_patch(socket, to: ~p"/files/#{id}")}
          _ -> {:noreply, put_flash(socket, :error, "Could not locate existing root.")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Init failed: #{inspect(reason)}")}
    end
  end

  # ── Progress messages from Dust.Daemon.FileSystem PubSub ──────────────

  @impl true
  def handle_info({:upload_progress, file_uuid, chunk, total}, socket) do
    {:noreply, update_progress(socket, file_uuid, :upload, chunk, total)}
  end

  def handle_info({:download_progress, file_uuid, chunk, total}, socket) do
    {:noreply, update_progress(socket, file_uuid, :download, chunk, total)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <%= if assigns[:needs_root?] do %>
        <div class="rounded-md border border-zinc-200 bg-white p-6 text-center">
          <h2 class="text-lg font-semibold text-zinc-900">No root directory yet</h2>
          <p class="mt-1 text-sm text-zinc-500">
            Initialize the filesystem to start uploading files.
          </p>
          <.button phx-click="init_root" class="mt-4">Create root directory</.button>
        </div>
      <% else %>
        <div class="flex items-center justify-between">
          <.breadcrumbs trail={@trail} />
          <.button phx-click="open_mkdir">New folder</.button>
        </div>

        <.upload_dropzone uploads={@uploads} />

        <.file_table dirs={@entries.dirs} files={@entries.files} progress={@progress} />
      <% end %>

      <.modal :if={@modal == :mkdir} on_close="close_modal" title="New folder">
        <form phx-submit="mkdir_submit" class="space-y-4">
          <.input name="name" id="mkdir-name" label="Name" required autocomplete="off" />
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="close_modal" class="text-sm text-zinc-500 hover:text-zinc-900">
              Cancel
            </button>
            <.button type="submit">Create</.button>
          </div>
        </form>
      </.modal>

      <.modal :if={@modal == :move} on_close="close_modal" title={"Move #{@move_target.type}"}>
        <p class="text-sm text-zinc-500">
          Move <span class="font-medium text-zinc-900">{@move_target.name}</span> to:
        </p>
        <%= if @move_candidates == [] do %>
          <p class="mt-4 text-sm text-zinc-500">No eligible destinations.</p>
        <% else %>
          <ul class="mt-3 max-h-80 space-y-1 overflow-y-auto rounded-md border border-zinc-200">
            <li :for={c <- @move_candidates}>
              <button
                type="button"
                phx-click="move_submit"
                phx-value-dest={c.id}
                class="flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-zinc-50"
              >
                <span class="text-zinc-400">📁</span>
                <span class="text-zinc-700">{c.path}</span>
              </button>
            </li>
          </ul>
        <% end %>
        <div class="mt-4 flex justify-end">
          <button type="button" phx-click="close_modal" class="text-sm text-zinc-500 hover:text-zinc-900">
            Cancel
          </button>
        </div>
      </.modal>

      <.modal :if={@modal == :rename} on_close="close_modal" title={"Rename #{@rename_target.type}"}>
        <form phx-submit="rename_submit" class="space-y-4">
          <.input
            name="name"
            id="rename-name"
            label="New name"
            value={@rename_target.current_name}
            required
            autocomplete="off"
          />
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="close_modal" class="text-sm text-zinc-500 hover:text-zinc-900">
              Cancel
            </button>
            <.button type="submit">Rename</.button>
          </div>
        </form>
      </.modal>
    </div>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp resolve_dir_id(nil) do
    case existing_root() do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :no_root}
    end
  end

  defp resolve_dir_id(""), do: resolve_dir_id(nil)
  defp resolve_dir_id(id) when is_binary(id), do: {:ok, id}

  defp existing_root do
    case String.trim(Dust.Utilities.Config.root_dir_id()) do
      "" ->
        find_root_in_crdt()

      id ->
        if FS.get_dir(id), do: {:ok, id}, else: find_root_in_crdt()
    end
  end

  defp find_root_in_crdt do
    case Enum.find(FS.all_dirs(), fn {_id, dir} -> Map.get(dir, :parent_id) == nil end) do
      {id, _dir} ->
        # Best-effort cache; fine if it fails (e.g. already set, no permission).
        _ = Dust.Utilities.Config.put(:root_dir_id, id)
        {:ok, id}

      _ ->
        :error
    end
  end

  defp refresh_listing(socket) do
    dir_id = socket.assigns.current_dir_id

    case dir_id && FS.ls(dir_id) do
      %{dirs: dirs, files: files} ->
        assign(socket,
          entries: %{dirs: dirs, files: files},
          trail: build_trail(dir_id),
          needs_root?: false
        )

      _ ->
        assign(socket, entries: %{dirs: [], files: []}, trail: build_trail(dir_id), needs_root?: false)
    end
  end

  defp build_trail(nil), do: []

  defp build_trail(dir_id) do
    walk_up(dir_id, [])
  end

  defp walk_up(nil, acc), do: acc

  defp walk_up(id, acc) when is_binary(id) do
    case FS.get_dir(id) do
      nil ->
        acc

      dir ->
        crumb = %{id: id, name: Map.get(dir, :name) || "root"}
        walk_up(Map.get(dir, :parent_id), [crumb | acc])
    end
  end

  # Returns destination directories the user may move `target` into.
  #
  # Always excludes the current parent (no-op move). For a directory target
  # also excludes the directory itself and every descendant to prevent
  # cycles. Each returned entry has `:id` and `:path` ("root / a / b").
  defp move_candidates(target, current_dir_id) do
    dirs = FS.all_dirs()
    excluded = excluded_ids(target, dirs) |> MapSet.put(current_dir_id)

    dirs
    |> Enum.reject(fn {id, _} -> MapSet.member?(excluded, id) end)
    |> Enum.map(fn {id, _} -> %{id: id, path: dir_path(id, dirs)} end)
    |> Enum.sort_by(& &1.path)
  end

  defp excluded_ids(%{type: "dir", id: dir_id}, dirs) do
    descendants(dir_id, dirs) |> MapSet.put(dir_id)
  end

  defp excluded_ids(_target, _dirs), do: MapSet.new()

  defp descendants(dir_id, dirs) do
    children =
      for {id, entry} <- dirs, Map.get(entry, :parent_id) == dir_id, into: MapSet.new(), do: id

    Enum.reduce(children, children, fn child, acc ->
      MapSet.union(acc, descendants(child, dirs))
    end)
  end

  defp dir_path(id, dirs), do: dir_path(id, dirs, [])

  defp dir_path(nil, _dirs, acc), do: Enum.join(acc, " / ")

  defp dir_path(id, dirs, acc) do
    case Map.get(dirs, id) do
      nil -> Enum.join(acc, " / ")
      entry -> dir_path(Map.get(entry, :parent_id), dirs, [Map.get(entry, :name) || "root" | acc])
    end
  end

  defp update_progress(socket, file_uuid, kind, chunk, total) do
    entry = %{kind: kind, chunk: chunk, total: total}

    progress =
      if chunk >= total do
        Map.delete(socket.assigns.progress, file_uuid)
      else
        Map.put(socket.assigns.progress, file_uuid, entry)
      end

    assign(socket, progress: progress)
  end
end
