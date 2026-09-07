defmodule Dust.Ui.FormatTest do
  use ExUnit.Case, async: true

  alias Dust.Ui.Format

  describe "file_icon/1" do
    test "maps media families by prefix" do
      assert Format.file_icon("image/png") == "hero-photo"
      assert Format.file_icon("image/svg+xml") == "hero-photo"
      assert Format.file_icon("video/mp4") == "hero-film"
      assert Format.file_icon("audio/mpeg") == "hero-musical-note"
    end

    test "maps common document, archive, and data types exactly" do
      assert Format.file_icon("application/pdf") == "hero-document-text"
      assert Format.file_icon(
               "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
             ) == "hero-document-text"

      assert Format.file_icon("application/zip") == "hero-archive-box"
      assert Format.file_icon("application/x-tar") == "hero-archive-box"

      assert Format.file_icon("text/csv") == "hero-table-cells"
      assert Format.file_icon(
               "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
             ) == "hero-table-cells"

      assert Format.file_icon(
               "application/vnd.openxmlformats-officedocument.presentationml.presentation"
             ) == "hero-presentation-chart-bar"

      assert Format.file_icon("application/json") == "hero-code-bracket"
    end

    test "falls back to a plain-text icon for other text/* types" do
      assert Format.file_icon("text/plain") == "hero-document-text"
      assert Format.file_icon("text/markdown") == "hero-document-text"
    end

    test "falls back to a generic document icon for nil, octet-stream, and unknowns" do
      assert Format.file_icon(nil) == "hero-document"
      assert Format.file_icon("application/octet-stream") == "hero-document"
      assert Format.file_icon("application/x-some-proprietary-thing") == "hero-document"
      assert Format.file_icon(:not_a_string) == "hero-document"
    end
  end
end
