defmodule Dust.Ui.FileTable do
  @moduledoc false
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: Dust.Ui.Endpoint,
    router: Dust.Ui.Router,
    statics: Dust.Ui.static_paths()

  import Dust.Ui.CoreComponents

  alias Dust.Ui.Format

  @doc """
  Breadcrumb trail. `trail` is a list of `%{id, name}` from root to
  current. The last entry is rendered un-linked.
  """
  attr :trail, :list, required: true

  def breadcrumbs(assigns) do
    ~H"""
    <nav class="flex items-center gap-1 text-sm text-zinc-500" aria-label="Breadcrumb">
      <%= for {crumb, idx} <- Enum.with_index(@trail) do %>
        <span :if={idx > 0} class="text-zinc-300">/</span>
        <%= if idx == length(@trail) - 1 do %>
          <span class="font-medium text-zinc-900">{crumb.name}</span>
        <% else %>
          <.link patch={~p"/files/#{crumb.id}"} class="hover:text-zinc-900">
            {crumb.name}
          </.link>
        <% end %>
      <% end %>
    </nav>
    """
  end

  @doc """
  Renders the directory/file table.
  """
  attr :dirs, :list, required: true
  attr :files, :list, required: true
  attr :progress, :map, default: %{}

  def file_table(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-lg border border-zinc-200 bg-white shadow-sm">
      <table class="min-w-full divide-y divide-zinc-200">
        <thead class="bg-zinc-50">
          <tr>
            <th class="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-zinc-500">
              Name
            </th>
            <th class="px-4 py-2 text-right text-xs font-semibold uppercase tracking-wide text-zinc-500">
              Size
            </th>
            <th class="px-4 py-2 text-left text-xs font-semibold uppercase tracking-wide text-zinc-500">
              Created
            </th>
            <th class="px-4 py-2 text-right text-xs font-semibold uppercase tracking-wide text-zinc-500">
              Actions
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100">
          <tr :if={@dirs == [] and @files == []}>
            <td colspan="4" class="px-4 py-8 text-center text-sm text-zinc-500">
              This directory is empty.
            </td>
          </tr>

          <tr :for={dir <- @dirs} class="hover:bg-zinc-50">
            <td class="px-4 py-2 text-sm">
              <.link patch={~p"/files/#{dir.id}"} class="flex items-center gap-2 font-medium text-zinc-900 hover:underline">
                <span class="text-zinc-400">📁</span>
                {dir.name}
              </.link>
            </td>
            <td class="px-4 py-2 text-right text-sm text-zinc-500">—</td>
            <td class="px-4 py-2 text-sm text-zinc-500">{Format.relative_time(Map.get(dir, :created_at))}</td>
            <td class="px-4 py-2 text-right text-sm">
              <div class="inline-flex gap-3">
                <button
                  type="button"
                  phx-click="open_rename"
                  phx-value-id={dir.id}
                  phx-value-type="dir"
                  phx-value-name={dir.name}
                  class="text-zinc-500 hover:text-zinc-900"
                >
                  Rename
                </button>
                <button
                  type="button"
                  phx-click="rm"
                  phx-value-id={dir.id}
                  phx-value-type="dir"
                  data-confirm={"Delete directory '#{dir.name}'?"}
                  class="text-rose-600 hover:text-rose-800"
                >
                  Delete
                </button>
              </div>
            </td>
          </tr>

          <tr :for={file <- @files} class="hover:bg-zinc-50">
            <td class="px-4 py-2 text-sm">
              <div class="flex items-center gap-2 font-medium text-zinc-900">
                <span class="text-zinc-400">📄</span>
                {file.name}
              </div>
              <div :if={p = @progress[file.id]} class="mt-1">
                <div class="h-1 w-full overflow-hidden rounded-full bg-zinc-100">
                  <div
                    class={[
                      "h-full transition-all",
                      p.kind == :download && "bg-sky-500",
                      p.kind == :upload && "bg-emerald-500"
                    ]}
                    style={"width: #{progress_percent(p)}%"}
                  >
                  </div>
                </div>
                <p class="mt-1 text-xs text-zinc-500">
                  {progress_label(p)} · {p.chunk}/{p.total}
                </p>
              </div>
            </td>
            <td class="px-4 py-2 text-right text-sm text-zinc-500">
              {Format.bytes(parse_int(Map.get(file, :size)))}
            </td>
            <td class="px-4 py-2 text-sm text-zinc-500">{Format.relative_time(Map.get(file, :created_at))}</td>
            <td class="px-4 py-2 text-right text-sm">
              <div class="inline-flex gap-3">
                <.link
                  href={~p"/download/#{file.id}"}
                  class="text-zinc-700 hover:text-zinc-900"
                >
                  Download
                </.link>
                <button
                  type="button"
                  phx-click="open_rename"
                  phx-value-id={file.id}
                  phx-value-type="file"
                  phx-value-name={file.name}
                  class="text-zinc-500 hover:text-zinc-900"
                >
                  Rename
                </button>
                <button
                  type="button"
                  phx-click="rm"
                  phx-value-id={file.id}
                  phx-value-type="file"
                  data-confirm={"Delete file '#{file.name}'?"}
                  class="text-rose-600 hover:text-rose-800"
                >
                  Delete
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp progress_percent(%{chunk: c, total: t}) when is_integer(t) and t > 0,
    do: trunc(c * 100 / t) |> min(100) |> max(0)

  defp progress_percent(_), do: 0

  defp progress_label(%{kind: :upload}), do: "Uploading"
  defp progress_label(%{kind: :download}), do: "Downloading"
  defp progress_label(_), do: ""

  @doc "Renders the drag-and-drop upload dropzone with a submit form."
  attr :uploads, :map, required: true

  def upload_dropzone(assigns) do
    ~H"""
    <form
      id="upload-form"
      phx-submit="upload_submit"
      phx-change="upload_validate"
      class="rounded-lg border-2 border-dashed border-zinc-300 bg-white p-6 text-center"
    >
      <p class="text-sm text-zinc-600">
        Drop files here or
        <label class="cursor-pointer text-zinc-900 underline">
          choose files
          <.live_file_input upload={@uploads.files} class="sr-only" />
        </label>
      </p>

      <%= for entry <- @uploads.files.entries do %>
        <div class="mt-3 text-left text-sm">
          <p class="text-zinc-700">{entry.client_name}</p>
          <div class="mt-1 h-1 w-full overflow-hidden rounded-full bg-zinc-100">
            <div class="h-full bg-zinc-700 transition-all" style={"width: #{entry.progress}%"}></div>
          </div>
          <p :if={msg = upload_errors_for_entry(@uploads.files, entry)} class="mt-1 text-xs text-rose-600">
            {msg}
          </p>
        </div>
      <% end %>

      <div :if={@uploads.files.entries != []} class="mt-4 flex justify-end gap-2">
        <.button type="submit" class="bg-emerald-600 hover:bg-emerald-700">Upload</.button>
      </div>
    </form>
    """
  end

  defp upload_errors_for_entry(config, entry) do
    case Phoenix.Component.upload_errors(config, entry) do
      [] -> nil
      [err | _] -> humanize_upload_error(err)
    end
  end

  defp humanize_upload_error(:too_large), do: "File is too large."
  defp humanize_upload_error(:not_accepted), do: "File type not accepted."
  defp humanize_upload_error(:too_many_files), do: "Too many files."
  defp humanize_upload_error(err), do: inspect(err)
end
