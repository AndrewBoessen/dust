defmodule Dust.UiTest do
  use ExUnit.Case
  doctest Dust.Ui

  test "greets the world" do
    assert Dust.Ui.hello() == :world
  end
end
