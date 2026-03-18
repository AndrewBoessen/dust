defmodule Dust.StorageTest do
  use ExUnit.Case
  doctest Dust.Storage

  test "greets the world" do
    assert Dust.Storage.hello() == :world
  end
end
