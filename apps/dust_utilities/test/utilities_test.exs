defmodule Dust.UtilitiesTest do
  use ExUnit.Case
  doctest Dust.Utilities

  test "greets the world" do
    assert Dust.Utilities.hello() == :world
  end
end
