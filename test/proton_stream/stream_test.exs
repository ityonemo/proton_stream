# SPDX-FileCopyrightText: 2025 Isaac Yonemoto
#
# SPDX-License-Identifier: Apache-2.0

defmodule ProtonStream.StreamTest do
  use ProtonStreamTest.Case

  describe "open/3" do
    test "opens process and receives stdout" do
      {:ok, ps} = ProtonStream.open("echo", ["hello"])
      assert_receive {^ps, {:data, "hello\n"}}, 1000
    end

    test "accepts cd option" do
      {:ok, ps} = ProtonStream.open("pwd", [], cd: "/tmp")
      assert_receive {^ps, {:data, path}}, 1000
      assert String.trim(path) == "/tmp"
    end

    test "accepts env option" do
      {:ok, ps} = ProtonStream.open("printenv", ["MY_TEST_VAR"], env: [{"MY_TEST_VAR", "test_value"}])
      assert_receive {^ps, {:data, "test_value\n"}}, 1000
    end
  end

  describe "stdout streaming" do
    test "receives multiple data messages" do
      {:ok, ps} = ProtonStream.open("/bin/sh", ["-c", "echo line1; echo line2; echo line3"])

      messages = collect_all_data(ps, [])
      combined = Enum.join(messages)

      assert combined =~ "line1"
      assert combined =~ "line2"
      assert combined =~ "line3"
    end

    test "handles large output" do
      {:ok, ps} = ProtonStream.open(test_path("print_a_lot.test"), [])
      data = collect_all_data(ps, []) |> Enum.join()
      assert byte_size(data) > 10_000
    end
  end

  describe "stderr streaming" do
    test "receives stderr as {:error, _}" do
      {:ok, ps} = ProtonStream.open(test_path("echo_stderr.test"), [])
      assert_receive {^ps, {:error, data}}, 1000
      assert data =~ "stderr message"
    end

    test "receives interleaved stdout and stderr separately" do
      {:ok, ps} = ProtonStream.open(test_path("echo_both.test"), [])

      {data_msgs, error_msgs} = collect_all_messages(ps)

      assert length(data_msgs) > 0
      assert length(error_msgs) > 0
    end
  end

  describe "stdin via {:command, _}" do
    test "sends data to process stdin" do
      {:ok, ps} = ProtonStream.open("cat", [])
      send(ps, {self(), {:command, "hello"}})
      assert_receive {^ps, {:data, "hello"}}, 1000
      send(ps, {self(), :close})
    end

    test "bidirectional communication with increment helper" do
      {:ok, ps} = ProtonStream.open(test_path("increment.test"), [])

      send(ps, {self(), {:command, "5\n"}})
      assert_receive {^ps, {:data, "6\n"}}, 1000

      send(ps, {self(), {:command, "99\n"}})
      assert_receive {^ps, {:data, "100\n"}}, 1000

      send(ps, {self(), {:command, "0\n"}})
      assert_receive {^ps, {:data, "1\n"}}, 1000

      send(ps, {self(), :close})
    end
  end

  describe "close" do
    test "closes port and sends :closed" do
      {:ok, ps} = ProtonStream.open(test_path("do_nothing.test"), [])
      send(ps, {self(), :close})
      assert_receive {^ps, :closed}, 1000
      refute Process.alive?(ps)
    end
  end

  describe "connect" do
    test "transfers ownership to new process" do
      {:ok, ps} = ProtonStream.open(test_path("chatty.test"), [])
      test_pid = self()

      new_owner = spawn(fn ->
        receive do
          {sender, {:data, _}} ->
            send(test_pid, {:new_owner_got_data, sender})
        after
          2000 -> send(test_pid, :timeout)
        end
      end)

      send(ps, {self(), {:connect, new_owner}})
      assert_receive {^ps, :connected}, 1000
      assert_receive {:new_owner_got_data, ^ps}, 2000
    end
  end

  describe "exit handling" do
    test "sends EXIT on normal termination" do
      Process.flag(:trap_exit, true)
      {:ok, ps} = ProtonStream.open("true", [])
      assert_receive {:EXIT, ^ps, :normal}, 2000
    end

    test "sends EXIT with exit_status for non-zero exit" do
      Process.flag(:trap_exit, true)
      {:ok, ps} = ProtonStream.open("false", [])
      assert_receive {:EXIT, ^ps, {:exit_status, 1}}, 2000
    end

    test "handles signals as exit codes > 128" do
      Process.flag(:trap_exit, true)
      # SIGTERM = 15, so exit code = 128 + 15 = 143
      {:ok, ps} = ProtonStream.open(test_path("kill_self_with_signal.test"), [])
      assert_receive {:EXIT, ^ps, {:signal, 15}}, 2000
    end
  end

  describe "process cleanup" do
    test "kills child when owner crashes" do
      parent = self()

      pid = spawn(fn ->
        {:ok, ps} = ProtonStream.open(test_path("do_nothing.test"), [])
        os_pid = ProtonStream.os_pid(ps)
        send(parent, {:os_pid, os_pid})
        Process.sleep(:infinity)
      end)

      assert_receive {:os_pid, os_pid}, 1000
      assert os_pid_around?(os_pid)

      Process.exit(pid, :kill)
      Process.sleep(100)

      refute os_pid_around?(os_pid)
    end
  end

  # Helper functions

  defp collect_all_data(ps, acc) do
    receive do
      {^ps, {:data, data}} -> collect_all_data(ps, [data | acc])
      {^ps, {:error, _}} -> collect_all_data(ps, acc)
      {^ps, :closed} -> Enum.reverse(acc)
      {:EXIT, ^ps, _} -> Enum.reverse(acc)
    after
      1000 -> Enum.reverse(acc)
    end
  end

  defp collect_all_messages(ps, data_acc \\ [], error_acc \\ []) do
    receive do
      {^ps, {:data, data}} -> collect_all_messages(ps, [data | data_acc], error_acc)
      {^ps, {:error, data}} -> collect_all_messages(ps, data_acc, [data | error_acc])
      {^ps, :closed} -> {Enum.reverse(data_acc), Enum.reverse(error_acc)}
      {:EXIT, ^ps, _} -> {Enum.reverse(data_acc), Enum.reverse(error_acc)}
    after
      1000 -> {Enum.reverse(data_acc), Enum.reverse(error_acc)}
    end
  end
end
