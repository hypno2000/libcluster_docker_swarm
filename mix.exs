defmodule Cluster.Strategy.DockerSwarm.MixProject do
  use Mix.Project

  def project do
    [
      app: :libcluster_docker_swarm,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:libcluster, "~> 3.0"},
      {:inet_ext, "~> 0.4.0"},
      {:tesla, "~> 1.1"},
    ]
  end
end
