defmodule Dust.Core.FitnessTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Dust.Core.Fitness
  alias Dust.Core.Fitness.{Observation, NodeEMA, ModelStore}

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp start_model_store!() do
    fitness_model_path = Dust.Utilities.File.fitness_models_dir()

    start_supervised!({CubDB, data_dir: fitness_model_path, name: Dust.Core.Database})
    start_supervised!({ModelStore, [db: Dust.Core.Database]})
  end

  setup_all do
    Application.stop(:dust_core)

    on_exit(fn ->
      Application.ensure_all_started(:dust_core)
    end)
  end

  setup %{tmp_dir: tmp_dir} do
    old_env = Application.get_env(:dust_utilities, :persist_dir)
    Application.put_env(:dust_utilities, :persist_dir, tmp_dir)
    start_model_store!()

    on_exit(fn ->
      if old_env do
        Application.put_env(:dust_utilities, :persist_dir, old_env)
      else
        Application.delete_env(:dust_utilities, :persist_dir)
      end
    end)

    :ok
  end

  # ── Observation ───────────────────────────────────────────────────────────

  describe "Observation" do
    test "can be constructed with success: true" do
      obs = %Observation{success: true, latency_ms: 30.0, bandwidth: 50.0}
      assert obs.success == true
      assert obs.latency_ms == 30.0
      assert obs.bandwidth == 50.0
    end

    test "can be constructed with success: false and nil metrics" do
      obs = %Observation{success: false, latency_ms: nil, bandwidth: nil}
      assert obs.success == false
      assert is_nil(obs.latency_ms)
      assert is_nil(obs.bandwidth)
    end

    test "raises if enforce_keys are missing" do
      assert_raise ArgumentError, fn ->
        struct!(Observation, %{})
      end
    end
  end

  # ── NodeEMA ───────────────────────────────────────────────────────────────

  describe "NodeEMA.new/0" do
    test "returns conservative default values" do
      model = NodeEMA.new()
      assert model.success_rate == 0.5
      assert model.latency_ms == 100.0
      assert model.bandwidth == 10.0
    end
  end

  describe "NodeEMA.update/2 on success" do
    test "moves success_rate toward 1.0" do
      model = NodeEMA.new()
      obs = %Observation{success: true, latency_ms: 20.0, bandwidth: 80.0}
      updated = NodeEMA.update(model, obs)

      assert updated.success_rate > model.success_rate
    end

    test "moves latency_ms toward the observed value" do
      model = NodeEMA.new()
      obs = %Observation{success: true, latency_ms: 20.0, bandwidth: 80.0}
      updated = NodeEMA.update(model, obs)

      assert updated.latency_ms < model.latency_ms
    end

    test "moves bandwidth toward the observed value" do
      model = NodeEMA.new()
      obs = %Observation{success: true, latency_ms: 20.0, bandwidth: 80.0}
      updated = NodeEMA.update(model, obs)

      assert updated.bandwidth > model.bandwidth
    end

    test "applies EMA formula correctly" do
      model = NodeEMA.new()
      obs = %Observation{success: true, latency_ms: 20.0, bandwidth: 80.0}
      updated = NodeEMA.update(model, obs)

      alpha = 0.3
      assert_in_delta updated.success_rate, alpha * 1.0 + (1 - alpha) * 0.5, 0.0001
      assert_in_delta updated.latency_ms, alpha * 20.0 + (1 - alpha) * 100.0, 0.0001
      assert_in_delta updated.bandwidth, alpha * 80.0 + (1 - alpha) * 10.0, 0.0001
    end

    test "converges toward observed values over many successes" do
      obs = %Observation{success: true, latency_ms: 10.0, bandwidth: 100.0}
      model = Enum.reduce(1..50, NodeEMA.new(), fn _, m -> NodeEMA.update(m, obs) end)

      assert_in_delta model.latency_ms, 10.0, 1.0
      assert_in_delta model.bandwidth, 100.0, 1.0
      assert_in_delta model.success_rate, 1.0, 0.01
    end
  end

  describe "NodeEMA.update/2 on failure" do
    test "moves success_rate toward 0.0" do
      model = NodeEMA.new()
      obs = %Observation{success: false, latency_ms: nil, bandwidth: nil}
      updated = NodeEMA.update(model, obs)

      assert updated.success_rate < model.success_rate
    end

    test "does not change latency_ms on failure" do
      model = NodeEMA.new()
      obs = %Observation{success: false, latency_ms: nil, bandwidth: nil}
      updated = NodeEMA.update(model, obs)

      assert updated.latency_ms == model.latency_ms
    end

    test "does not change bandwidth on failure" do
      model = NodeEMA.new()
      obs = %Observation{success: false, latency_ms: nil, bandwidth: nil}
      updated = NodeEMA.update(model, obs)

      assert updated.bandwidth == model.bandwidth
    end

    test "converges success_rate toward 0.0 over many failures" do
      obs = %Observation{success: false, latency_ms: nil, bandwidth: nil}
      model = Enum.reduce(1..50, NodeEMA.new(), fn _, m -> NodeEMA.update(m, obs) end)

      assert model.success_rate < 0.01
    end

    test "retains last known good latency and bandwidth after failures" do
      good_obs = %Observation{success: true, latency_ms: 15.0, bandwidth: 90.0}
      bad_obs = %Observation{success: false, latency_ms: nil, bandwidth: nil}

      model =
        NodeEMA.new()
        |> NodeEMA.update(good_obs)
        |> NodeEMA.update(bad_obs)
        |> NodeEMA.update(bad_obs)

      assert model.latency_ms < 100.0
      assert model.bandwidth > 10.0
    end
  end

  describe "NodeEMA.score/1" do
    test "returns a positive score for the default model" do
      assert NodeEMA.score(NodeEMA.new()) > 0.0
    end

    test "higher bandwidth produces a higher score given equal other metrics" do
      low_bw = %NodeEMA{success_rate: 1.0, latency_ms: 30.0, bandwidth: 10.0}
      high_bw = %NodeEMA{success_rate: 1.0, latency_ms: 30.0, bandwidth: 100.0}

      assert NodeEMA.score(high_bw) > NodeEMA.score(low_bw)
    end

    test "lower latency produces a higher score given equal other metrics" do
      high_lat = %NodeEMA{success_rate: 1.0, latency_ms: 200.0, bandwidth: 50.0}
      low_lat = %NodeEMA{success_rate: 1.0, latency_ms: 10.0, bandwidth: 50.0}

      assert NodeEMA.score(low_lat) > NodeEMA.score(high_lat)
    end

    test "higher success_rate produces a higher score given equal other metrics" do
      low_sr = %NodeEMA{success_rate: 0.2, latency_ms: 30.0, bandwidth: 50.0}
      high_sr = %NodeEMA{success_rate: 0.9, latency_ms: 30.0, bandwidth: 50.0}

      assert NodeEMA.score(high_sr) > NodeEMA.score(low_sr)
    end

    test "score formula matches expected value" do
      model = %NodeEMA{success_rate: 0.8, latency_ms: 50.0, bandwidth: 40.0}
      expected = 0.8 * 40.0 / (1.0 + 50.0 / 100.0)

      assert_in_delta NodeEMA.score(model), expected, 0.0001
    end
  end

  # ── ModelStore ────────────────────────────────────────────────────────────

  describe "ModelStore.get/1" do
    test "returns default model for an unknown node" do
      assert ModelStore.get(:"unknown-node") == NodeEMA.new()
    end

    test "returns stored model after an update" do
      obs = %Observation{success: true, latency_ms: 25.0, bandwidth: 60.0}
      updated = ModelStore.update(:"node-a", obs)

      assert ModelStore.get(:"node-a") == updated
    end
  end

  describe "ModelStore.update/2" do
    test "returns the updated model" do
      obs = %Observation{success: true, latency_ms: 25.0, bandwidth: 60.0}
      updated = ModelStore.update(:"node-a", obs)

      assert updated.latency_ms < 100.0
      assert updated.bandwidth > 10.0
      assert updated.success_rate > 0.5
    end

    test "accumulates multiple observations" do
      obs = %Observation{success: true, latency_ms: 10.0, bandwidth: 100.0}

      ModelStore.update(:"node-a", obs)
      ModelStore.update(:"node-a", obs)
      model = ModelStore.update(:"node-a", obs)

      assert model.latency_ms < 70.0
      assert model.bandwidth > 40.0
    end

    test "different node ids maintain independent models" do
      ModelStore.update(:"fast-node", %Observation{
        success: true,
        latency_ms: 10.0,
        bandwidth: 100.0
      })

      ModelStore.update(:"slow-node", %Observation{success: false, latency_ms: nil, bandwidth: nil})

      assert ModelStore.get(:"fast-node").success_rate > ModelStore.get(:"slow-node").success_rate
    end
  end

  describe "ModelStore persistence" do
    test "persists models to disk on update" do
      obs = %Observation{success: true, latency_ms: 25.0, bandwidth: 60.0}
      ModelStore.update(:"node-a", obs)

      fitness_model_path = Dust.Utilities.File.fitness_models_dir()

      assert File.exists?(fitness_model_path)
    end

    test "reloads models from disk on restart" do
      obs = %Observation{success: true, latency_ms: 25.0, bandwidth: 60.0}
      updated = ModelStore.update(:"node-a", obs)

      # Restart with same path — simulates an application restart
      stop_supervised!(ModelStore)
      start_supervised!({ModelStore, [db: Dust.Core.Database]})

      assert ModelStore.get(:"node-a") == updated
    end

    test "starts cleanly with no persist file" do
      assert ModelStore.get(:"any-node") == NodeEMA.new()
    end
  end

  # ── Fitness public API ────────────────────────────────────────────────────

  describe "Fitness.score/1" do
    test "returns default score for a node never interacted with" do
      assert Fitness.score(:"never-seen") == NodeEMA.new() |> NodeEMA.score()
    end

    test "score increases after successful interactions" do
      initial_score = Fitness.score(:"node-a")
      Fitness.record(:"node-a", %Observation{success: true, latency_ms: 10.0, bandwidth: 100.0})

      assert Fitness.score(:"node-a") > initial_score
    end

    test "score decreases after failed interactions" do
      good_obs = %Observation{success: true, latency_ms: 10.0, bandwidth: 100.0}
      bad_obs = %Observation{success: false, latency_ms: nil, bandwidth: nil}

      Enum.each(1..5, fn _ -> Fitness.record(:"node-a", good_obs) end)
      good_score = Fitness.score(:"node-a")

      Enum.each(1..5, fn _ -> Fitness.record(:"node-a", bad_obs) end)

      assert Fitness.score(:"node-a") < good_score
    end
  end

  describe "Fitness.record/2" do
    test "returns the updated NodeEMA model" do
      obs = %Observation{success: true, latency_ms: 30.0, bandwidth: 50.0}
      updated = Fitness.record(:"node-a", obs)

      assert %NodeEMA{} = updated
      assert updated.latency_ms < 100.0
    end

    test "score reflects the most recently recorded observation" do
      obs = %Observation{success: true, latency_ms: 10.0, bandwidth: 100.0}
      Fitness.record(:"node-a", obs)

      assert_in_delta Fitness.score(:"node-a"), NodeEMA.score(ModelStore.get(:"node-a")), 0.0001
    end
  end
end
