defmodule DustDaemonTest do
  use ExUnit.Case
  doctest DustDaemon

  test "greets the world" do
    assert DustDaemon.hello() == :world
  end
end
