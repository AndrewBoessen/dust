defmodule BridgeTest do
  use ExUnit.Case
  doctest Bridge

  test "greets the world" do
    assert Bridge.hello() == :world
  end
end
