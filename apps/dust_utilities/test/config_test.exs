defmodule Dust.Utilities.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Dust.Utilities.Config

  setup %{tmp_dir: tmp_dir} do
    old_env = Application.get_env(:dust_utilities, :config)
    Application.put_env(:dust_utilities, :config, %{persist_dir: tmp_dir})

    on_exit(fn ->
      if old_env do
        Application.put_env(:dust_utilities, :config, old_env)
      else
        Application.delete_env(:dust_utilities, :config)
      end
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "node_name" do
    test "defaults to \"dust\" when no override is set", %{tmp_dir: tmp_dir} do
      Config.load!()
      assert Config.node_name() == "dust"
      assert File.read!(Path.join(tmp_dir, "node_name")) == "dust\n"
    end

    test "put/2 persists a valid name to YAML and the boot file", %{tmp_dir: tmp_dir} do
      Config.load!()

      assert :ok = Config.put(:node_name, "alice")
      assert Config.node_name() == "alice"
      assert File.read!(Path.join(tmp_dir, "node_name")) == "alice\n"

      yaml = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert yaml =~ "node_name: alice"
    end

    test "rejects names with illegal characters" do
      Config.load!()

      assert {:error, {:node_name, :invalid_format, "has space"}} =
               Config.put(:node_name, "has space")

      assert {:error, {:node_name, :invalid_format, "-leading-dash"}} =
               Config.put(:node_name, "-leading-dash")

      assert {:error, {:node_name, :invalid_format, ""}} =
               Config.put(:node_name, "")

      # Stays at the default
      assert Config.node_name() == "dust"
    end

    test "accepts alphanumerics, dashes, and underscores" do
      Config.load!()

      for name <- ["dust", "node1", "my-node", "my_node", "A1_b-2"] do
        assert :ok = Config.put(:node_name, name), "expected #{inspect(name)} to be accepted"
      end
    end

    test "reading YAML with a custom node_name surfaces that value on next load!", %{
      tmp_dir: tmp_dir
    } do
      Config.load!()
      :ok = Config.put(:node_name, "bob")

      # Simulate a fresh boot: reset the env so load! has to re-read the YAML.
      Application.put_env(:dust_utilities, :config, %{persist_dir: tmp_dir})
      Config.load!()

      assert Config.node_name() == "bob"
      assert File.read!(Path.join(tmp_dir, "node_name")) == "bob\n"
    end
  end
end
