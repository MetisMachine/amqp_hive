defmodule AmqpHiveClient.Consumer do
  use GenServer
  use AMQP
  require Logger

  def start_link(consumer, connection_name) do
    GenServer.start_link(__MODULE__, {consumer, connection_name})
  end

  def child_spec(consumer, connection_name) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [consumer, connection_name]},
      restart: :temporary
    }
  end

  def init({consumer, connection_name}) do
    # res = AmqpHiveClient.Connection.request_channel(connection_name, self())
    Process.send_after(self(), :ensure_channel, 5_000)
    {:ok, {consumer, nil, %{parent: connection_name}}}
  end

  def handle_call({:swarm, :begin_handoff}, _from, state) do
    # Logger.info("[SWARM] BEGIN HANDoff #{inspect(state)}")
    # {:reply, {:resume, 2000}, state}
    {:reply, :ignore, state}
  end

  def handle_call(other, _from, state) do
    Logger.info("[CONSUMER HANDLE CALL] #{inspect(other)}")
    {:reply, :ok, state}
  end
  # called after the process has been restarted on its new node,
  # and the old process' state is being handed off. This is only
  # sent if the return to `begin_handoff` was `{:resume, state}`.
  # **NOTE**: This is called *after* the process is successfully started,
  # so make sure to design your processes around this caveat if you
  # wish to hand off state like this.
  def handle_cast({:swarm, :end_handoff, delay}, state) do
    Logger.info("[SWARM] END HANDoff #{inspect(state)}")
    {:noreply, state}
  end
  # called when a network split is healed and the local process
  # should continue running, but a duplicate process on the other
  # side of the split is handing off its state to us. You can choose
  # to ignore the handoff state, or apply your own conflict resolution
  # strategy
  def handle_cast({:swarm, :resolve_conflict, _delay}, state) do
    Logger.info("[SWARM] Resolve conflicts #{inspect(state)}")
    {:noreply, state}
  end


  def handle_cast({:channel_available, chan}, {consumer, channel, attrs} = state) do
    Process.monitor(chan.pid)

    queue = Map.get(consumer, :queue, "")
    queue_options = Map.get(consumer, :options, [durable: true])
    prefetch_count = Map.get(consumer, :prefetch_count, 10)

    Basic.qos(chan, prefetch_count: prefetch_count)
    res = AMQP.Queue.declare(chan, queue, queue_options)
    {:ok, consumer_tag} = Basic.consume(chan, queue)
    newattrs = Map.put(attrs, :consumer_tag, consumer_tag)
    {:noreply, {consumer, chan, newattrs}}
  end

  def handle_cast(
        {:stop, reason},
        {consumer, _chan, %{parent: connection_name} = options} = state
      ) do
    Logger.debug(fn -> "Handle Stop Consumer CAST: #{inspect(reason)}" end)
    # consumer_name = Map.get(consumer, :name)

    # res =
    #   GenServer.cast(
    #     AmqpHiveClient.ConnectionManager,
    #     {:remove_consumer, consumer_name, connection_name}
    #   )

    {:noreply, state}
  end

  def handle_cast(:finished, {consumer, channel, %{consumer_tag: tag}} = state) do
    # Logger.debug(fn -> "[CONSUMER] HANDLE Cast Finished Queue = #{inspect(state)}" end)
    case channel do
      nil -> 
        {:stop, :normal, state}
      chan -> 
        # res = AMQP.Basic.cancel(chan, tag)
        if Process.alive?(chan.pid) do      
          case Map.get(consumer, :queue) do
            nil -> nil
            queue -> 
               GenServer.cast(AmqpHiveClient.QueueHandler, {:delete_queue, chan, queue})
                # AMQP.Queue.delete(chan, queue, [])
          end
        end
        {:noreply, state}
        # {:stop, :normal, state}
    end
    # Process.exit(self(), :normal)
  end

  def handle_cast(other, state) do
    Logger.debug(fn -> "Un-Handled Consumer CAST: #{inspect(other)} #{inspect(state)}" end)
    {:noreply, state}
  end

  def handle_info(:timeout, state) do
    Logger.info("[Timeout] #{inspect(state)}")
    # Process.send_after(self(), :timeout, delay)
    {:noreply, state}
  end
  # this message is sent when this process should die
  # because it is being moved, use this as an opportunity
  # to clean up
  def handle_info({:swarm, :die}, state) do
    Logger.info("[SWARM] DIE #{inspect(state)}")
    {:stop, :shutdown, state}
  end
  
  def handle_info(:ensure_channel, {consumer, channel, %{parent: connection_name}} = state) do
    if is_nil(channel) do
      res = AmqpHiveClient.Connection.request_channel(connection_name, self())
      # Process.send_after(self(), :ensure_channel, 5_000)
    end
    # Logger.debug(fn -> "[CONSUMER] basic consume #{inspect(consumer_tag)}" end)
    {:noreply, state}
  end


  # Confirmation sent by the broker after registering this process as a consumer
  def handle_info({:basic_consume_ok, %{consumer_tag: consumer_tag}}, {consumer, chan, attrs} = state) do
    # Logger.debug(fn -> "[CONSUMER] basic consume #{inspect(consumer_tag)}" end)
    newattrs = Map.put(attrs, :consumer_tag, consumer_tag)
    {:noreply, {consumer, chan, newattrs}}
  end

  # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
  def handle_info({:basic_cancel, %{consumer_tag: consumer_tag}}, {consumer, chan, attrs} = state) do
    # Logger.debug(fn -> "[CONSUMER] basic cancel #{inspect(consumer_tag)}" end)

    {:stop, :normal, state}
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  def handle_info({:basic_cancel_ok, %{consumer_tag: consumer_tag}}, {consumer, chan, attrs} = state) do
    # Logger.debug(fn -> "[CONSUMER] basic cancel_ok #{inspect(consumer_tag)}" end)
    {:stop, :normal, state}
  end

  def handle_info({:basic_deliver, payload, meta}, {consumer, chan, other} = state) do
    pid = self()
    # Logger.debug(fn -> "Basic deliver in #{inspect(pid)} #{inspect(payload)}" end)
    
    spawn(fn -> consume(pid, chan, payload, meta, state) end)
    {:noreply, state}
  end

  def handle_info({:DOWN, _, :process, _pid, reason}, state) do
    # Logger.debug(fn -> "Consumer Down, reason: #{inspect(reason)} state = #{inspect(state)}" end)
    {:noreply, state}
  end

  def handle_info(
        {:EXIT, _, {:shutdown, {:connection_closing, {:server_initiated_close, _, reason}}}},
        state
      ) do
    Logger.debug(fn -> "HANDLE EXIT: reason = #{inspect(reason)} : State= #{inspect(state)}" end)
    {:noreply, state}
  end

  def handle_info({:EXIT, _, reason}, state) do
    Logger.debug(fn -> "EXIT REASON #{inspect(reason)}" end)
    {:stop, reason, state}
  end

  def handle_info(:stop, state) do
    # Logger.debug(fn -> "HANDLE kill channel state = #{inspect(state)}" end)
    # GenServer.cast(self(), {:stop, "stopme"})
    {:noreply, state}
  end

  def handle_info(:kill_channel, {_, channel, _} = state) do
    Logger.debug(fn -> "HANDLE kill channel state = #{inspect(state)}" end)
    # AMQP.Channel.close(channel)
    {:noreply, state}
  end

  def handle_info(:finished, {consumer, channel, %{consumer_tag: tag}} = state) do
    # Logger.debug(fn -> "HANDLE Finished Queue = #{inspect(state)}" end)
    case channel do
      nil -> 
        {:stop, :normal, state}
      chan -> 
        if Process.alive?(chan.pid) do      
          case Map.get(consumer, :queue) do
            nil -> nil
            queue -> 
              GenServer.cast(AmqpHiveClient.QueueHandler, {:delete_queue, chan, queue})
                # AMQP.Queue.delete(chan, queue, [])
          end
        end
        {:noreply, state}
        # {:stop, :normal, state}
    end
  end

  def handle_info(:finished, {consumer, channel, attrs} = state) do
    # Logger.debug(fn -> "HANDLE Finished Queue = #{inspect(state)}" end)
    case channel do
      nil -> 
        {:stop, :normal, state}
      chan -> 
        if Process.alive?(chan.pid) do      
          case Map.get(consumer, :queue) do
            nil -> nil
            queue -> 
              GenServer.cast(AmqpHiveClient.QueueHandler, {:delete_queue, chan, queue})
          end
        end
        {:noreply, state}
    end
  end

  def handle_info(reason, state) do
    Logger.info(fn -> "UN-HANDLE INFO: reason = #{inspect(reason)} state = #{inspect(state)}" end)
    {:noreply, state}
  end


  def terminate(other, {_consumer, channel, _options} = state) do
    Logger.debug(fn -> "[CONSUMER TERMINATE] other = #{inspect(other)} and stuff = #{inspect(state)}" end)
    :shutdown
  end

  def channel_available(pid, chan) do
    GenServer.cast(pid, {:channel_available, chan})
  end

  defp consume(pid, channel, payload, meta, state) do
    # Logger.info(fn -> "Consumer Meta is #{inspect(meta)}" end)

    response = 
      case handle_route(pid, payload, meta, state) do
        %{"error" => msg} ->
          :ok = Basic.reject channel, meta.delivery_tag, requeue: not meta.redelivered
          %{"error" => msg}
        response ->  
          AMQP.Basic.ack(channel, meta.delivery_tag)
          response 
      end
    
    case meta.reply_to do
      r when is_nil(r) or r == :undefined ->
        nil

      reply_to ->
        AMQP.Basic.publish(
          channel,
          "",
          meta.reply_to,
          "#{Poison.encode!(response)}",
          correlation_id: meta.correlation_id
        )
    end
  rescue
    # Requeue unless it's a redelivered message.
    # This means we will retry consuming a message once in case of exception
    # before we give up and have it moved to the error queue
    #
    # You might also want to catch :exit signal in production code.
    # Make sure you call ack, nack or reject otherwise comsumer will stop
    # receiving messages.
    exception ->      
      Logger.error(fn -> "Error consume #{inspect(exception)}" end)
      :ok = Basic.reject channel, meta.delivery_tag, requeue: not meta.redelivered
      Logger.error(fn -> "Error consuming payload: #{payload}" end)
  end

  def handle_route(pid, payload, %{routing_key: "rpc.create_deployment"} = meta, {_consumer, _other, %{parent: connection_name}}) do
    context = Poison.decode!(payload)
    case Map.get(context, "deployment_id") do
      nil ->  %{"error" => "No Deployment ID" }
      dep_id -> 
        name = "#{connection_name}-#{dep_id}"
        consumer = %{name: dep_id, queue: dep_id}

        AmqpHive.ConsumerRegistry.register_consumer(name, consumer, connection_name)
        %{"success" =>  "Waiting for Deployment "}
    end    
  rescue 
    exception -> 
      Logger.error(fn -> "Error handle_route rpc.create_deployment #{inspect(exception)}" end)
      %{"error" => "Error Creating Addons for #{payload}"}
  end

  

  def handle_route(pid, payload, meta, state) do
    # Logger.info("handle route #{inspect(state)}")    
    body = Poison.decode!(payload)
    handle_action(pid, body, meta, state)
  rescue 
    exception -> 
      Logger.error(fn -> "Error converting #{payload} to json" end)
      %{"error" => "Error converting #{payload} to json"}
  end

  def handle_action(pid, %{"action" => "finished"} = payload, meta, state) do    
    # Logger.info("Handle finish action #{inspect(pid)}")
    GenServer.cast(pid, :finished)
    %{"success" => "Finished"}
  end

  def handle_action(pid, %{"action" => "log", "msg" => msg} = payload, meta, state) do    
    # Logger.info("Handle LOG action #{inspect(msg)}")
    # GenServer.cast(pid, :finished)
    GenServer.cast(AmqpHive.LoadTest, :message_received)
    %{"success" => "Logged"}
  end

  def handle_action(pid, payload, meta, state) do
    %{"error" => "No Action Handler"}
  end
end


# send(Swarm.whereis_name("dev_connection-11111111-58b5-4318-8063-7f425bf902f6"), :finished)