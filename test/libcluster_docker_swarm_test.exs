defmodule Cluster.Strategy.DockerSwarmTest do
  use ExUnit.Case
  doctest Cluster.Strategy.DockerSwarm

  test "greets the world" do
    assert Cluster.Strategy.DockerSwarm.hello() == :world
  end
end
