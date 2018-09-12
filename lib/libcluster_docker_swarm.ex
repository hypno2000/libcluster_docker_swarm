defmodule Cluster.Strategy.DockerSwarm do
  use GenServer
  use Cluster.Strategy
  use Tesla

  require Logger

  alias Cluster.Strategy.State

  plug Tesla.Middleware.JSON

  @default_polling_interval 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init([%State{} = state]) do
    state = state |> Map.put(:meta, MapSet.new())

    {:ok, state, 0}
  end

  def handle_info(:timeout, state) do
    handle_info(:load, state)
  end

  def handle_info(
        :load,
        %State{
          topology: topology,
          connect: connect,
          disconnect: disconnect,
          list_nodes: list_nodes
        } = state
      ) do
    new_nodelist = get_nodes(state)
    added = MapSet.difference(new_nodelist, state.meta)
    removed = MapSet.difference(state.meta, new_nodelist)

    new_nodelist =
      Cluster.Strategy.disconnect_nodes(
        topology,
        disconnect,
        list_nodes,
        MapSet.to_list(removed)
      )
      |> case do
        :ok ->
          Logger.info("Docker nodes disconnected", nodes: new_nodelist)
          new_nodelist

        {:error, bad_nodes} ->
          # Add back the nodes which should have been removed, but which couldn't be for some reason
          Logger.error("Docker nodes could not be removed", nodes: bad_nodes)

          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.put(acc, n)
          end)
      end

    new_nodelist =
      Cluster.Strategy.connect_nodes(
        topology,
        connect,
        list_nodes,
        MapSet.to_list(added)
      )
      |> case do
        :ok ->
          Logger.info("Docker nodes connected", nodes: new_nodelist)
          new_nodelist

        {:error, bad_nodes} ->
          # Remove the nodes which should have been added, but couldn't be for some reason
          Logger.error("Docker nodes could not be added", nodes: bad_nodes)

          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.delete(acc, n)
          end)
      end

    Process.send_after(
      self(),
      :load,
      Keyword.get(state.config, :polling_interval, @default_polling_interval)
    )

    {:noreply, %{state | :meta => new_nodelist}}
  end

  @impl true
  def handle_info(_, state) do
    {:noreply, state}
  end

  @spec get_nodes(State.t()) :: MapSet.t(atom())
  def get_nodes(%State{config: config}) do
    stack_name = Keyword.fetch!(config, :stack_name)
    service_name = Keyword.fetch!(config, :service_name)
    network_name = Keyword.fetch!(config, :network_name)
    node_username = Keyword.fetch!(config, :node_username)

    swarm_manager = get_docker_host() |> get_swarm_manager()

    get_container_ids(swarm_manager, stack_name, service_name)
    |> Enum.map(&get_container_ip(swarm_manager, &1, network_name))
    |> Enum.map(&String.to_atom("#{node_username}@#{&1}"))
    |> MapSet.new()
  end

  defp get_docker_host() do
    [{_, docker_host} | _] = :inet_ext.gateways()
    docker_host
  end

  defp get_swarm_manager(docker_host) do
    %Tesla.Env{body: %{"Swarm" => %{"RemoteManagers" => [%{"Addr" => ip_with_port} | _]}}} =
      get!("http://#{docker_host}:2375/info")

    [ip | _] = ip_with_port |> String.split(":")
    ip
  end

  defp get_container_ids(swarm_manager, stack_name, service_name) do
    %Tesla.Env{body: body} =
      get!("http://#{swarm_manager}:2375/tasks",
        query: [
          filters:
            "{\"service\":[\"#{stack_name}_#{service_name}\"],\"desired-state\":[\"running\"]}"
        ]
      )

    body
    |> Enum.map(fn %{"Status" => %{"ContainerStatus" => %{"ContainerID" => container_id}}} ->
      container_id
    end)
  end

  defp get_container_ip(swarm_manager, container_id, network_name) do
    %Tesla.Env{
      body: %{"NetworkSettings" => %{"Networks" => %{^network_name => %{"IPAddress" => ip}}}}
    } = get!("http://#{swarm_manager}:2375/containers/#{container_id}/json")

    ip
  end
end
