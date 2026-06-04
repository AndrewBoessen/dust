defmodule Dust.Ui.ErrorHTML do
  @moduledoc false
  use Dust.Ui, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
