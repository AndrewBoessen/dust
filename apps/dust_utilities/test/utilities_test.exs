defmodule Dust.UtilitiesTest do
  use ExUnit.Case

  test "persist_dir returns a non-empty string" do
    assert is_binary(Dust.Utilities.File.persist_dir())
    assert Dust.Utilities.File.persist_dir() != ""
  end

  test "master_key_file is inside persist_dir" do
    assert String.starts_with?(
             Dust.Utilities.File.master_key_file(),
             Dust.Utilities.File.persist_dir()
           )
  end
end
