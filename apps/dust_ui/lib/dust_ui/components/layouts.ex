defmodule Dust.Ui.Layouts do
  @moduledoc """
  Root and application layouts for the Dust web UI.
  """
  use Dust.Ui, :html

  embed_templates "layouts/*"
end
