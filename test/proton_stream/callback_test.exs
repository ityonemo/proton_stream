# SPDX-FileCopyrightText: 2025 Isaac Yonemoto
#
# SPDX-License-Identifier: Apache-2.0

defmodule ProtonStream.CallbackTest do
  use ProtonStreamTest.Case

  # Test callback module that collects events and reports to test process
  defmodule TestWorker do
    use GenServer
    @behaviour ProtonStream

    # init_arg is passed to init/1, opts are ProtonStream options
    def start_link({command, args, init_arg, opts}) do
      ProtonStream.start_link(__MODULE__, command, args, init_arg, opts)
    end

    @impl GenServer
    def init(test_pid) do
      send(test_pid, {:worker_started, self()})
      {:ok, %{test_pid: test_pid, buffer: ""}}
    end

    @impl ProtonStream
    def handle_stdout(data, state) do
      send(state.test_pid, {:stdout, data})
      {:noreply, %{state | buffer: state.buffer <> data}}
    end

    @impl ProtonStream
    def handle_stderr(data, state) do
      send(state.test_pid, {:stderr, data})
      {:noreply, state}
    end

    @impl ProtonStream
    def handle_exit(reason, state) do
      send(state.test_pid, {:exit, reason})
      {:stop, reason, state}
    end

    # Custom GenServer callbacks
    @impl GenServer
    def handle_call(:get_buffer, _from, state) do
      {:reply, state.buffer, state}
    end

    @impl GenServer
    def handle_cast({:send_to_test, msg}, state) do
      send(state.test_pid, {:cast_received, msg})
      {:noreply, state}
    end
  end

  describe "start_link/5 with callback module" do
    test "starts process and calls init/1 with init_arg" do
      {:ok, pid} = TestWorker.start_link({"echo", ["hello"], self(), []})
      assert_receive {:worker_started, ^pid}, 1000
      assert Process.alive?(pid)
    end

    test "passes ProtonStream options correctly" do
      {:ok, pid} = TestWorker.start_link({"pwd", [], self(), [cd: "/tmp"]})
      assert_receive {:worker_started, ^pid}, 1000
      assert_receive {:stdout, path}, 1000
      assert String.trim(path) == "/tmp"
    end

    test "supports :name option for process registration" do
      name = :"test_worker_#{System.unique_integer([:positive])}"
      {:ok, pid} = TestWorker.start_link({"echo", ["hello"], self(), [name: name]})
      assert_receive {:worker_started, ^pid}, 1000
      assert Process.whereis(name) == pid
    end
  end

  describe "handle_stdout/2 callback" do
    test "is called when stdout data is received" do
      {:ok, _pid} = TestWorker.start_link({"echo", ["hello"], self(), []})
      assert_receive {:worker_started, _}, 1000
      assert_receive {:stdout, "hello\n"}, 1000
    end

    test "receives multiple stdout messages" do
      {:ok, _pid} = TestWorker.start_link({"/bin/sh", ["-c", "echo one; echo two"], self(), []})
      assert_receive {:worker_started, _}, 1000

      # Collect stdout messages
      stdout = collect_messages(:stdout, [])
      combined = Enum.join(stdout)
      assert combined =~ "one"
      assert combined =~ "two"
    end
  end

  describe "handle_stderr/2 callback" do
    test "is called when stderr data is received" do
      {:ok, _pid} = TestWorker.start_link({test_path("echo_stderr.test"), [], self(), []})
      assert_receive {:worker_started, _}, 1000
      assert_receive {:stderr, data}, 1000
      assert data =~ "stderr"
    end
  end

  describe "handle_exit/2 callback" do
    test "is called on normal exit" do
      {:ok, _pid} = TestWorker.start_link({"true", [], self(), []})
      assert_receive {:worker_started, _}, 1000
      assert_receive {:exit, :normal}, 2000
    end

    test "is called with exit_status for non-zero exit" do
      {:ok, _pid} = TestWorker.start_link({"false", [], self(), []})
      assert_receive {:worker_started, _}, 1000
      assert_receive {:exit, {:exit_status, 1}}, 2000
    end

    test "is called with signal for signaled process" do
      {:ok, _pid} =
        TestWorker.start_link({test_path("kill_self_with_signal.test"), [], self(), []})

      assert_receive {:worker_started, _}, 1000
      assert_receive {:exit, {:signal, 15}}, 2000
    end
  end

  describe "GenServer callbacks" do
    test "handle_call/3 works" do
      {:ok, pid} = TestWorker.start_link({"cat", [], self(), []})
      assert_receive {:worker_started, ^pid}, 1000

      # Send some data via the ProtonStream protocol and check buffer via handle_call
      send(pid, {self(), {:command, "test data"}})
      Process.sleep(100)

      buffer = GenServer.call(pid, :get_buffer)
      assert buffer =~ "test data"
    end

    test "handle_cast/2 works" do
      {:ok, pid} = TestWorker.start_link({test_path("do_nothing.test"), [], self(), []})
      assert_receive {:worker_started, ^pid}, 1000

      GenServer.cast(pid, {:send_to_test, :hello})
      assert_receive {:cast_received, :hello}, 1000
    end
  end

  describe "process lifecycle" do
    test "child is killed when callback module stops" do
      {:ok, pid} = TestWorker.start_link({test_path("do_nothing.test"), [], self(), []})
      assert_receive {:worker_started, ^pid}, 1000

      os_pid = ProtonStream.os_pid(pid)
      assert os_pid_around?(os_pid)

      GenServer.stop(pid)
      Process.sleep(100)

      refute os_pid_around?(os_pid)
    end
  end

  # Helper to collect messages of a specific type
  defp collect_messages(type, acc) do
    receive do
      {^type, data} -> collect_messages(type, [data | acc])
      {:exit, _} -> Enum.reverse(acc)
    after
      500 -> Enum.reverse(acc)
    end
  end
end
