# SPDX-FileCopyrightText: 2018 Frank Hunleth
# SPDX-FileCopyrightText: 2023 Ben Youngblood
# SPDX-FileCopyrightText: 2025 Isaac Yonemoto
#
# SPDX-License-Identifier: Apache-2.0

defmodule ProtonStream do
  @moduledoc """
  ProtonStream provides a streaming API for OS processes that mirrors Elixir's Port module.

  This library is derived from `MuonTrap` by Frank Hunleth,
  with a new streaming API and bidirectional stdin/stdout/stderr support.

  ProtonStream can be used in two modes:

  1. **Message-based mode** - via `open/3`, where the calling process receives messages
  2. **Callback module mode** - via `start_link/4`, where a GenServer module handles events

  ## Message-based Mode

  Use `open/3` to start a process. The calling process becomes the "owner" and
  receives messages about stdout, stderr, and process termination.

  ### Messages TO ProtonStream (from owner)

  - `{pid, {:command, binary}}` - send data to child's stdin
  - `{pid, :close}` - close the port
  - `{pid, {:connect, new_pid}}` - transfer ownership to another process

  ### Messages FROM ProtonStream (to owner)

  - `{pid, {:data, data}}` - stdout from child process
  - `{pid, {:error, data}}` - stderr from child process
  - `{pid, :closed}` - reply to close request
  - `{pid, :connected}` - reply to connect request
  - `{:EXIT, pid, reason}` - process termination (when trapping exits)

  ### Example

      {:ok, ps} = ProtonStream.open("cat", [])
      send(ps, {self(), {:command, "hello"}})

      receive do
        {^ps, {:data, data}} -> IO.puts("Got: \#{data}")
      end

      send(ps, {self(), :close})

  ## Callback Module Mode

  For integration with supervision trees, use `start_link/4` with a callback module
  that implements both `GenServer` and the `ProtonStream` behaviour.

  ### Callbacks

  The following callbacks must be implemented:

  - `c:GenServer.init/1` - called when the process starts, returns initial state
  - `c:handle_stdout/2` - called when stdout data is received
  - `c:handle_stderr/2` - called when stderr data is received
  - `c:handle_exit/2` - called when the child process exits

  ### Example

      defmodule MyWorker do
        use GenServer
        @behaviour ProtonStream

        def start_link(args) do
          ProtonStream.start_link(__MODULE__, "my_command", [], args)
        end

        @impl GenServer
        def init(args) do
          {:ok, %{buffer: "", args: args}}
        end

        @impl ProtonStream
        def handle_stdout(data, state) do
          {:noreply, %{state | buffer: state.buffer <> data}}
        end

        @impl ProtonStream
        def handle_stderr(data, state) do
          IO.puts(:stderr, data)
          {:noreply, state}
        end

        @impl ProtonStream
        def handle_exit(reason, state) do
          {:stop, reason, state}
        end
      end

  The module can then be added to a supervision tree:

      children = [
        {MyWorker, [some: :args]}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  ### Callback Return Values

  - `c:GenServer.init/1` returns `{:ok, state}` or `{:stop, reason}`
  - `c:handle_stdout/2` returns `{:noreply, state}` or `{:stop, reason, state}`
  - `c:handle_stderr/2` returns `{:noreply, state}` or `{:stop, reason, state}`
  - `c:handle_exit/2` returns `{:stop, reason, state}`

  ### GenServer Callbacks

  The callback module may also implement `c:GenServer.handle_call/3`,
  `c:GenServer.handle_cast/2`, `c:GenServer.handle_info/2`, `c:handle_continue/2`,
  and `c:terminate/2` to handle synchronous requests, asynchronous requests,
  messages, continuations, and cleanup.

  ## Configuring cgroups

  On most Linux distributions, use `cgcreate` to create a new cgroup:

  ```sh
  sudo cgcreate -a $(whoami) -g memory,cpu:proton_stream
  ```

  Then use the `:cgroup_controllers` and `:cgroup_base` options.
  """

  use GenServer

  import Bitwise
  require Logger

  # Behaviour callbacks for callback module mode
  @callback handle_stdout(data :: binary(), state :: term()) ::
              {:noreply, new_state :: term()}
              | {:noreply, new_state :: term(), timeout() | :hibernate | {:continue, term()}}
              | {:stop, reason :: term(), new_state :: term()}

  @callback handle_stderr(data :: binary(), state :: term()) ::
              {:noreply, new_state :: term()}
              | {:noreply, new_state :: term(), timeout() | :hibernate | {:continue, term()}}
              | {:stop, reason :: term(), new_state :: term()}

  @callback handle_exit(reason :: term(), state :: term()) ::
              {:stop, reason :: term(), new_state :: term()}

  @optional_callbacks handle_stdout: 2,
                      handle_stderr: 2,
                      handle_exit: 2

  # Frame protocol tags (C -> Elixir)
  @frame_tag_stdout 0x01
  @frame_tag_stderr 0x02
  @frame_tag_exit 0x03

  # Frame protocol commands (Elixir -> C)
  @frame_cmd_stdin 0x01
  @frame_cmd_close 0x02
  @frame_cmd_ack 0x03

  defstruct [:port, :owner, :command, :args, :buffer, :cgroup_path, :state]

  @type t :: %__MODULE__{
          port: port() | nil,
          owner: pid(),
          command: binary(),
          args: [binary()],
          buffer: binary(),
          cgroup_path: binary() | nil,
          state: term()
        }

  # Public API

  @doc """
  Open a new OS process and return a handle to it.

  Returns `{:ok, pid}` on success or `{:error, reason}` on failure.
  The calling process becomes the owner and will receive messages.

  ## Options

    * `:cd` - the directory to run the command in
    * `:env` - an enumerable of tuples containing environment key-value as binary
    * `:arg0` - sets the command arg0
    * `:cgroup_controllers` - run the command under the specified cgroup controllers
    * `:cgroup_base` - create a temporary path under the specified cgroup path
    * `:cgroup_path` - explicitly specify a path to use
    * `:cgroup_sets` - set a cgroup controller parameter before running the command
    * `:delay_to_sigkill` - milliseconds before SIGKILL if SIGTERM doesn't work (default 500ms)
    * `:uid` - run the command using the specified uid or username
    * `:gid` - run the command using the specified gid or group
    * `:stdio_window` - flow control window size in bytes (default 10KB)

  ## Example

      {:ok, ps} = ProtonStream.open("echo", ["hello"])
      receive do
        {^ps, {:data, "hello\\n"}} -> :ok
      end
  """
  @spec open(binary(), [binary()], keyword()) :: GenServer.on_start()
  def open(command, args \\ [], opts \\ []) when is_binary(command) and is_list(args) do
    GenServer.start_link(__MODULE__, {command, args, opts, self()})
  end

  @spec start_link(module, binary(), [binary()], term(), keyword()) :: GenServer.on_start()
  def start_link(module, command, args \\ [], init_arg \\ [], opts \\ []) do
    {genserver_opts, proton_opts} = Keyword.split(opts, [:name])

    GenServer.start_link(
      __MODULE__,
      {command, args, proton_opts, module, init_arg},
      genserver_opts
    )
  end

  @doc """
  Send data to the process's stdin.

  This is equivalent to `send(ps, {self(), {:command, data}})`.
  """
  @spec command(pid(), iodata()) :: :ok
  def command(server, data) do
    send(server, {self(), {:command, data}})
    :ok
  end

  @doc """
  Close the process.

  This is equivalent to `send(ps, {self(), :close})`.
  The caller will receive `{ps, :closed}` when complete.
  """
  @spec close(pid()) :: :ok
  def close(server) do
    send(server, {self(), :close})
    :ok
  end

  @doc """
  Transfer ownership to a new process.

  The current owner will receive `{ps, :connected}` and the new owner
  will start receiving data messages.
  """
  @spec connect(pid(), pid()) :: :ok
  def connect(server, new_owner) do
    send(server, {self(), {:connect, new_owner}})
    :ok
  end

  @doc """
  Return the OS process ID of the child process.
  """
  @spec os_pid(pid()) :: non_neg_integer() | nil
  def os_pid(server) do
    GenServer.call(server, :"$os_pid")
  end

  @doc """
  Return the absolute path to the muontrap executable.
  """
  defdelegate muontrap_path, to: ProtonStream.Port

  # GenServer Callbacks

  @impl true
  def init({command, args, opts, owner}) when is_pid(owner) do
    Process.flag(:trap_exit, true)
    Process.link(owner)

    options = ProtonStream.Options.validate(:stream, command, args, opts)
    muontrap_args = build_muontrap_args(options)
    port_options = build_port_options(options)

    {:ok, new(muontrap_args, port_options, command, args, options, owner)}
  end

  def init({command, args, opts, module, init_arg}) when is_atom(module) do
    Process.flag(:trap_exit, true)

    options = ProtonStream.Options.validate(:stream, command, args, opts)
    muontrap_args = build_muontrap_args(options)
    port_options = build_port_options(options)

    case module.init(init_arg) do
      {:ok, callback_state} ->
        {:ok, new(muontrap_args, port_options, command, args, options, module, callback_state)}

      {:stop, reason} ->
        {:stop, reason}

      other ->
        {:stop, {:bad_return_value, other}}
    end
  end

  defp new(muontrap_args, port_options, command, args, options, owner, state \\ nil) do
    port =
      Port.open(
        {:spawn_executable, muontrap_path()},
        [:binary, :exit_status, {:args, muontrap_args} | port_options]
      )

    %__MODULE__{
      port: port,
      owner: owner,
      command: command,
      args: args,
      buffer: <<>>,
      cgroup_path: options[:cgroup_path],
      state: state
    }
  end

  @impl true
  def handle_call(:"$os_pid", _from, state) do
    os_pid =
      case Port.info(state.port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    {:reply, os_pid, state}
  end

  def handle_call(msg, from, %{owner: module} = state) when is_atom(module) do
    if !function_exported?(module, :handle_call, 3) do
      raise "attempted to call #{inspect(module)} but no handle_call/3 clause was provided"
    end

    case module.handle_call(msg, from, state.state) do
      {:reply, reply, new_state} ->
        {:reply, reply, %{state | state: new_state}}

      {:reply, reply, new_state, timeout_or_continue} ->
        {:reply, reply, %{state | state: new_state}, timeout_or_continue}

      {:noreply, new_state} ->
        {:noreply, %{state | state: new_state}}

      {:noreply, new_state, timeout_or_continue} ->
        {:noreply, %{state | state: new_state}, timeout_or_continue}

      {:stop, reason, reply, new_state} ->
        {:stop, reason, reply, %{state | state: new_state}}

      {:stop, reason, new_state} ->
        {:stop, reason, %{state | state: new_state}}
    end
  end

  @impl true
  def handle_cast(msg, %{owner: module} = state) when is_atom(module) do
    if !function_exported?(module, :handle_cast, 2) do
      raise "attempted to cast to #{inspect(module)} but no handle_cast/2 clause was provided"
    end

    case module.handle_cast(msg, state.state) do
      {:noreply, new_state} ->
        {:noreply, %{state | state: new_state}}

      {:noreply, new_state, timeout_or_continue} ->
        {:noreply, %{state | state: new_state}, timeout_or_continue}

      {:stop, reason, new_state} ->
        {:stop, reason, %{state | state: new_state}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, owner: owner} = state)
      when is_pid(owner) do
    {frames, buffer} = parse_frames(state.buffer <> data)

    Enum.each(frames, fn
      {:stdout, payload} ->
        send(owner, {self(), {:data, payload}})

      {:stderr, payload} ->
        send(owner, {self(), {:error, payload}})

      {:exit_status, status} ->
        handle_exit_status(status, state)
    end)

    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({port, {:data, data}}, %{port: port, owner: module} = state)
      when is_atom(module) do
    {frames, buffer} = parse_frames(state.buffer <> data)

    result =
      Enum.reduce_while(frames, {:noreply, %{state | buffer: buffer}}, fn frame, {_, acc_state} ->
        case handle_callback_frame(frame, module, acc_state) do
          {:noreply, new_state} -> {:cont, {:noreply, new_state}}
          {:noreply, new_state, extra} -> {:cont, {:noreply, new_state, extra}}
          {:stop, reason, new_state} -> {:halt, {:stop, reason, new_state}}
        end
      end)

    result
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    # The exit status frame should have been received already via the framed protocol
    # This is just cleanup - mark port as nil since it's already closed
    {:stop, :normal, %{state | port: nil}}
  end

  # Owner commands (message-based mode)
  def handle_info({from, {:command, data}}, %{owner: from} = state) when is_pid(from) do
    send_stdin_frame(state.port, data)
    {:noreply, state}
  end

  def handle_info({from, :close}, %{owner: from} = state) when is_pid(from) do
    send_close_frame(state.port)
    Port.close(state.port)
    send(from, {self(), :closed})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({from, {:connect, new_pid}}, %{owner: from} = state) when is_pid(from) do
    Process.link(new_pid)
    Process.unlink(from)
    send(from, {self(), :connected})
    {:noreply, %{state | owner: new_pid}}
  end

  # Commands for callback module mode - any process can send
  def handle_info({_from, {:command, data}}, %{owner: module} = state) when is_atom(module) do
    send_stdin_frame(state.port, data)
    {:noreply, state}
  end

  def handle_info({from, :close}, %{owner: module} = state) when is_atom(module) do
    send_close_frame(state.port)
    Port.close(state.port)
    send(from, {self(), :closed})
    {:stop, :normal, %{state | port: nil}}
  end

  # Ignore messages from non-owner (message-based mode only)
  def handle_info({_from, {:command, _}}, %{owner: owner} = state) when is_pid(owner),
    do: {:noreply, state}

  def handle_info({_from, :close}, %{owner: owner} = state) when is_pid(owner),
    do: {:noreply, state}

  def handle_info({_from, {:connect, _}}, state), do: {:noreply, state}

  # Handle linked process exit
  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state) do
    Logger.debug("ProtonStream: owner exited with #{inspect(reason)}")
    {:stop, reason, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.debug("ProtonStream: port exited with #{inspect(reason)}")
    {:stop, reason, state}
  end

  def handle_info(msg, state) when is_pid(state.owner) do
    Logger.warning("ProtonStream: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  def handle_info(msg, %{owner: module} = state) when is_atom(module) do
    if !function_exported?(module, :handle_info, 2) do
      raise "attempted to send message to #{inspect(module)} but no handle_info/2 clause was provided"
    end

    case module.handle_info(msg, state.state) do
      {:noreply, new_state} ->
        {:noreply, %{state | state: new_state}}

      {:noreply, new_state, timeout_or_continue} ->
        {:noreply, %{state | state: new_state}, timeout_or_continue}

      {:stop, reason, new_state} ->
        {:stop, reason, %{state | state: new_state}}
    end
  end

  @impl true
  def handle_continue(continue_arg, %{owner: module} = state) when is_atom(module) do
    if !function_exported?(module, :handle_continue, 2) do
      raise "attempted to continue #{inspect(module)} but no handle_continue/2 clause was provided"
    end

    case module.handle_continue(continue_arg, state.state) do
      {:noreply, new_state} ->
        {:noreply, %{state | state: new_state}}

      {:noreply, new_state, timeout_or_continue} ->
        {:noreply, %{state | state: new_state}, timeout_or_continue}

      {:stop, reason, new_state} ->
        {:stop, reason, %{state | state: new_state}}
    end
  end

  @impl true
  def terminate(reason, %{owner: module} = state) when is_atom(module) do
    if function_exported?(module, :terminate, 2) do
      module.terminate(reason, state.state)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private helpers

  defp build_muontrap_args(options) do
    # Always use framed mode for the new streaming API
    args = ["--framed"]

    args =
      case options[:delay_to_sigkill] do
        nil -> args
        ms -> args ++ ["--delay-to-sigkill", to_string(ms)]
      end

    args =
      case options[:cgroup_path] do
        nil -> args
        path -> args ++ ["--group", path]
      end

    args =
      Enum.reduce(options[:cgroup_controllers] || [], args, fn controller, acc ->
        acc ++ ["--controller", controller]
      end)

    args =
      Enum.reduce(options[:cgroup_sets] || [], args, fn {_controller, key, value}, acc ->
        acc ++ ["--set", "#{key}=#{value}"]
      end)

    args =
      case options[:uid] do
        nil -> args
        uid -> args ++ ["--uid", to_string(uid)]
      end

    args =
      case options[:gid] do
        nil -> args
        gid -> args ++ ["--gid", to_string(gid)]
      end

    args =
      case options[:stdio_window] do
        nil -> args
        window -> args ++ ["--stdio-window", to_string(window)]
      end

    args =
      case options[:arg0] do
        nil -> args
        arg0 -> args ++ ["--arg0", arg0]
      end

    # Add the command and its arguments
    args ++ ["--", options[:command] | options[:args]]
  end

  defp build_port_options(options) do
    port_opts = []

    port_opts =
      case options[:cd] do
        nil -> port_opts
        cd -> [{:cd, cd} | port_opts]
      end

    port_opts =
      case options[:env] do
        nil -> port_opts
        env -> [{:env, Enum.to_list(env)} | port_opts]
      end

    port_opts =
      case options[:parallelism] do
        nil -> port_opts
        p -> [{:parallelism, p} | port_opts]
      end

    port_opts
  end

  # Frame parsing - parses framed binary protocol from C helper
  defp parse_frames(data, acc \\ [])

  defp parse_frames(<<tag, len_hi, len_lo, rest::binary>>, acc) do
    len = (len_hi <<< 8) + len_lo

    case rest do
      <<payload::binary-size(len), remaining::binary>> ->
        frame = decode_frame(tag, payload)
        parse_frames(remaining, [frame | acc])

      _ ->
        {Enum.reverse(acc), <<tag, len_hi, len_lo, rest::binary>>}
    end
  end

  defp parse_frames(incomplete, acc) do
    {Enum.reverse(acc), incomplete}
  end

  defp decode_frame(@frame_tag_stdout, payload), do: {:stdout, payload}
  defp decode_frame(@frame_tag_stderr, payload), do: {:stderr, payload}

  defp decode_frame(@frame_tag_exit, <<b0, b1, b2, b3>>) do
    status = (b0 <<< 24) + (b1 <<< 16) + (b2 <<< 8) + b3
    # Handle signed 32-bit integer
    status =
      if status >= 0x80000000 do
        status - 0x100000000
      else
        status
      end

    {:exit_status, status}
  end

  defp decode_frame(tag, _payload) do
    Logger.warning("ProtonStream: unknown frame tag: #{tag}")
    {:unknown, tag}
  end

  # Handle frames for callback module mode
  defp handle_callback_frame({:stdout, payload}, module, state) do
    if function_exported?(module, :handle_stdout, 2) do
      case module.handle_stdout(payload, state.state) do
        {:noreply, new_state} ->
          {:noreply, %{state | state: new_state}}

        {:noreply, new_state, extra} ->
          {:noreply, %{state | state: new_state}, extra}

        {:stop, reason, new_state} ->
          {:stop, reason, %{state | state: new_state}}
      end
    else
      {:noreply, state}
    end
  end

  defp handle_callback_frame({:stderr, payload}, module, state) do
    if function_exported?(module, :handle_stderr, 2) do
      case module.handle_stderr(payload, state.state) do
        {:noreply, new_state} ->
          {:noreply, %{state | state: new_state}}

        {:noreply, new_state, extra} ->
          {:noreply, %{state | state: new_state}, extra}

        {:stop, reason, new_state} ->
          {:stop, reason, %{state | state: new_state}}
      end
    else
      {:noreply, state}
    end
  end

  defp handle_callback_frame({:exit_status, status}, module, state) do
    reason = exit_reason(status)

    if function_exported?(module, :handle_exit, 2) do
      case module.handle_exit(reason, state.state) do
        {:stop, stop_reason, new_state} ->
          {:stop, stop_reason, %{state | state: new_state}}
      end
    else
      {:stop, reason, state}
    end
  end

  defp handle_callback_frame({:unknown, _tag}, _module, state) do
    {:noreply, state}
  end

  defp handle_exit_status(status, state) do
    reason = exit_reason(status)

    # Send EXIT to owner if they're trapping exits
    # The GenServer will stop after this
    send(state.owner, {:EXIT, self(), reason})
  end

  defp exit_reason(0), do: :normal
  defp exit_reason(status) when status > 128, do: {:signal, status - 128}
  defp exit_reason(status), do: {:exit_status, status}

  # Send framed command to write to child's stdin
  defp send_stdin_frame(port, data) when is_binary(data) do
    len = byte_size(data)

    if len > 65535 do
      # Split into multiple frames
      send_stdin_frame(port, binary_part(data, 0, 65535))
      send_stdin_frame(port, binary_part(data, 65535, len - 65535))
    else
      frame = <<@frame_cmd_stdin, len >>> 8, len &&& 0xFF, data::binary>>
      Port.command(port, frame)
    end
  end

  defp send_stdin_frame(port, data) when is_list(data) do
    send_stdin_frame(port, IO.iodata_to_binary(data))
  end

  # Send close command
  defp send_close_frame(port) do
    frame = <<@frame_cmd_close, 0, 0>>
    Port.command(port, frame)
  end

  # Send acknowledgment (flow control)
  @doc false
  def send_ack(port, bytes) when bytes > 0 do
    # Each ack byte is value+1, so max single ack is 256 bytes
    acks = build_acks(bytes, [])
    len = length(acks)
    frame = <<@frame_cmd_ack, len >>> 8, len &&& 0xFF, :erlang.list_to_binary(acks)::binary>>
    Port.command(port, frame)
  end

  defp build_acks(0, acc), do: Enum.reverse(acc)

  defp build_acks(bytes, acc) when bytes >= 256 do
    build_acks(bytes - 256, [255 | acc])
  end

  defp build_acks(bytes, acc) do
    build_acks(0, [bytes - 1 | acc])
  end
end
