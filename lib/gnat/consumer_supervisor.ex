defmodule Gnat.ConsumerSupervisor do
  use GenServer
  require Logger

  @moduledoc """
  A process that can supervise consumers for you

  If you want to subscribe to a few topics and have that subscription last across restarts for you, then this worker can be of help.
  It also spawns a supervised `Task` for each message it receives.
  This way errors in message processing don't crash the consumers, but you will still get SASL reports that you can send to services like honeybadger.

  To use this just add an entry to your supervision tree like this:

  ```
  consumer_supervisor_settings = %{
    connection_name: :name_of_supervised_connection,
    module: MyApp.Server, # a module that implements the Gnat.Server behaviour
    subscription_topics: [
      %{topic: "rpc.MyApp.search", queue_group: "rpc.MyApp.search"},
      %{topic: "rpc.MyApp.create", queue_group: "rpc.MyApp.create"},
    ],
  }
  worker(Gnat.ConsumerSupervisor, [consumer_supervisor_settings, [name: :rpc_consumer]], shutdown: 30_000)
  ```

  The second argument is a keyword list that gets used as the GenServer options so you can pass a name that you want to register for the consumer process if you like. The `:consuming_function` specifies which module and function to call when messages arrive. The function will be called with a single argument which is a `t:Gnat.message/0` just like you get when you call `Gnat.sub/4` directly.

  You can have a single consumer that subscribes to multiple topics or multiple consumers that subscribe to different topics and call different consuming functions. It is recommended that your `ConsumerSupervisor`s are present later in your supervision tree than your `ConnectionSupervisor`. That way during a shutdown the `ConsumerSupervisor` can attempt a graceful shutdown of the consumer before shutting down the connection.

  It's also possible to pass a `%{consuming_function: {YourModule, :your_function}}` rather than a `:module` in your settings.
  In that case no error handling or replying is taking care of for you, it will be up to your function to take whatever action you want with each message.
  """
  @spec start_link(map(), keyword()) :: GenServer.on_start
  def start_link(settings, options \\ []) do
    GenServer.start_link(__MODULE__, settings, options)
  end

  @impl GenServer
  def init(settings) do
    Process.flag(:trap_exit, true)
    {:ok, task_supervisor_pid} = Task.Supervisor.start_link()
    connection_name = Map.get(settings, :connection_name)
    subscription_topics = Map.get(settings, :subscription_topics)

    state = %{
      connection_name: connection_name,
      connection_pid: nil,
      status: :disconnected,
      subscription_topics: subscription_topics,
      subscriptions: [],
      task_supervisor_pid: task_supervisor_pid,
    }

    cond do
      Map.has_key?(settings, :module) ->
        state = Map.put(state, :module, settings.module)
        send self(), :connect
        {:ok, state}

      Map.has_key?(settings, :consuming_function) ->
        state = Map.put(state, :consuming_function, settings.consuming_function)
        send self(), :connect
        {:ok, state}

      true ->
        {:error, "You must provide a module or consuming function for the consumer supervisor"}
    end
  end

  @impl GenServer
  def handle_info(:connect, %{connection_name: name}=state) do
    case Process.whereis(name) do
      nil ->
        Process.send_after(self(), :connect, 2_000)
        {:noreply, state}
      connection_pid ->
        _ref = Process.monitor(connection_pid)
        subscriptions = Enum.map(state.subscription_topics, fn(topic_and_queue_group) ->
          topic = Map.fetch!(topic_and_queue_group, :topic)
          {:ok, subscription} = case Map.get(topic_and_queue_group, :queue_group) do
            nil -> Gnat.sub(connection_pid, self(), topic)
            queue_group -> Gnat.sub(connection_pid, self(), topic, queue_group: queue_group)
          end
          subscription
        end)
        {:noreply, %{state | status: :connected, connection_pid: connection_pid, subscriptions: subscriptions}}
    end
  end

  def handle_info({:DOWN, _ref, :process, connection_pid, _reason}, %{connection_pid: connection_pid}=state) do
    Process.send_after(self(), :connect, 2_000)
    {:noreply, %{state | status: :disconnected, connection_pid: nil, subscriptions: []}}
  end
  # Ignore DOWN and task result messages from the spawned tasks
  def handle_info({:DOWN, _ref, :process, task_pid, reason}, state) do
    Logger.error "#{__MODULE__} received :DOWN signal from #{inspect task_pid}, reason:  #{inspect reason}"
    {:noreply, state}
  end
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:EXIT, supervisor_pid, _reason}, %{task_supervisor_pid: supervisor_pid}=state) do
    {:ok, task_supervisor_pid} = Task.Supervisor.start_link()
    {:noreply, Map.put(state, :task_supervisor_pid, task_supervisor_pid)}
  end

  def handle_info({:msg, gnat_message}, %{module: module} = state) do
    Task.Supervisor.async_nolink(state.task_supervisor_pid, Gnat.Server, :execute, [module, gnat_message])
    {:noreply, state}
  end

  def handle_info({:msg, gnat_message}, %{consuming_function: {mod, fun}}=state) do
    Task.Supervisor.async_nolink(state.task_supervisor_pid, mod, fun, [gnat_message])
    {:noreply, state}
  end

  def handle_info(other, state) do
    Logger.error "#{__MODULE__} received unexpected message #{inspect other}"
    {:noreply, state}
  end

  @impl GenServer
  def terminate(:shutdown, state) do
    Logger.info "#{__MODULE__} starting graceful shutdown"
    Enum.each(state.subscriptions, fn(subscription) ->
      :ok = Gnat.unsub(state.connection_pid, subscription)
    end)
    Process.sleep(500) # wait for final messages from broker
    receive_final_broker_messages(state)
    wait_for_empty_task_supervisor(state)
    Logger.info "#{__MODULE__} finished graceful shutdown"
  end
  def terminate(reason, _state) do
    Logger.error "#{__MODULE__} unexpected shutdown #{inspect reason}"
  end

  defp receive_final_broker_messages(state) do
    receive do
      info ->
        handle_info(info, state)
        receive_final_broker_messages(state)
      after 0 ->
        :done
    end
  end

  defp wait_for_empty_task_supervisor(%{task_supervisor_pid: pid}=state) do
    case Task.Supervisor.children(pid) do
      [] -> :ok
      children ->
        Logger.info "#{__MODULE__}\t\t#{Enum.count(children)} tasks remaining"
        Process.sleep(1_000)
        wait_for_empty_task_supervisor(state)
    end
  end
end
