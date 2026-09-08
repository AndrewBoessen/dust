defmodule Dust.Ui.FileTableTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Dust.Ui.FileTable

  defp render_table(dirs, files) do
    render_component(&FileTable.file_table/1, dirs: dirs, files: files, progress: %{})
  end

  test "renders a collapsed three-dots action menu per row" do
    html =
      render_table(
        [%{id: "d1", name: "docs", created_at: nil}],
        [%{id: "f1", name: "notes.txt", mime: "text/plain", size: 12, created_at: nil}]
      )

    # one kebab trigger + one collapsed menu container per row
    assert html =~ ~s(id="row-menu-dir-d1")
    assert html =~ ~s(id="row-menu-file-f1")
    assert html =~ "hero-ellipsis-vertical"
    assert html =~ "phx-click-away"
    assert html =~ ~s(role="menu")

    # the menu starts hidden
    assert [_, _] = Regex.scan(~r/role="menu"[^>]*\bhidden\b/, html)
  end

  test "download stays a direct link outside the menu; rename/move/delete are in it" do
    html =
      render_table([], [
        %{id: "f1", name: "notes.txt", mime: "text/plain", size: 12, created_at: nil}
      ])

    assert html =~ "Download"
    assert html =~ "Rename"
    assert html =~ "Move"
    assert html =~ "Delete"

    # Download link precedes (is a sibling of, not inside) the menu panel
    [_, before_menu] = Regex.run(~r/(.*)<div id="row-menu-file-f1"/s, html)
    assert before_menu =~ ~s(href="/download/f1")

    assert html =~ ~s(phx-value-id="f1")
    assert html =~ ~s(phx-value-type="file")
    assert html =~ "Delete file &#39;notes.txt&#39;?"
  end

  test "no inline action buttons remain" do
    html = render_table([%{id: "d1", name: "docs", created_at: nil}], [])
    refute html =~ ~s(class="text-zinc-500 hover:text-zinc-900")
  end
end
