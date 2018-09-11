defmodule Cluster.Strategy.DockerSwarm do
  use GenServer
  use Cluster.Strategy
  use Tesla

  alias Cluster.Strategy.State

  plug(Tesla.Middleware.JSON)

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
    case get_nodes(state) do
      {:ok, new_nodelist} ->
        added = MapSet.difference(new_nodelist, state.meta)
        removed = MapSet.difference(state.meta, new_nodelist)

        new_nodelist =
          case Cluster.Strategy.disconnect_nodes(
                 topology,
                 disconnect,
                 list_nodes,
                 MapSet.to_list(removed)
               ) do
            :ok ->
              new_nodelist

            {:error, bad_nodes} ->
              # Add back the nodes which should have been removed, but which couldn't be for some reason
              Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
                MapSet.put(acc, n)
              end)
          end

        new_nodelist =
          case Cluster.Strategy.connect_nodes(
                 topology,
                 connect,
                 list_nodes,
                 MapSet.to_list(added)
               ) do
            :ok ->
              new_nodelist

            {:error, bad_nodes} ->
              # Remove the nodes which should have been added, but couldn't be for some reason
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

      _ ->
        Process.send_after(
          self(),
          :load,
          Keyword.get(state.config, :polling_interval, @default_polling_interval)
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_, state) do
    {:noreply, state}
  end

  @spec get_nodes(State.t()) :: {:ok, [atom()]} | {:error, []}
  defp get_nodes(%State{config: config}) do
    stack_name = Keyword.fetch!(config, :stack_name)
    service_name = Keyword.fetch!(config, :service_name)
    network_name = Keyword.fetch!(config, :network_name)
    node_username = Keyword.fetch!(config, :node_username)

    get_docker_host()
    |> get_swarm_manager()
    |> get_running_tasks(stack_name, service_name)
    |> Enum.map(fn %{"NetworksAttachments" => attachments} ->
      %{"Addresses" => [address_cidr | _]} =
        Enum.find(attachments, fn %{"Network" => %{"Spec" => %{Name: name}}} ->
          name == network_name
        end)

      [address | _] = address_cidr |> String.split("/")
      address
    end)
    |> Enum.map(&String.to_atom("#{node_username}@#{&1}"))
  end

  defp get_docker_host() do
    [{_, docker_host} | _] = :inet_ext.gateways()
    docker_host
  end

  defp get_swarm_manager(docker_host) do
    %{"Swarm" => %{"RemoteManagers" => [%{"Addr" => swarm_manager} | _]}} =
      get!("http://#{docker_host}:2375/info")

    swarm_manager
  end

  defp get_running_tasks(swarm_manager, stack_name, service_name) do
    get!("http://#{swarm_manager}:2375/tasks",
      query: [
        filters:
          "{\"service\":[\"#{stack_name}_#{service_name}\"],\"desired-state\":[\"running\"]}"
      ]
    )
  end
end
