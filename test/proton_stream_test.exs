# SPDX-FileCopyrightText: 2018 Frank Hunleth
# SPDX-FileCopyrightText: 2019 Jason Axelson
# SPDX-FileCopyrightText: 2023 Ben Youngblood
# SPDX-FileCopyrightText: 2023 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0

defmodule ProtonStreamTest do
  use ProtonStreamTest.Case

  defp run_muontrap(args) do
    # Directly invoke the muontrap port to reduce the amount of code
    # to debug if something breaks.
    port =
      Port.open(
        {:spawn_executable, ProtonStream.muontrap_path()},
        args: args
      )

    # The port starts asynchronously. If the test needs to register
    # a signal handler, this is problematic since we can beat it.
    # The right answer is to handshake with our test helper app.
    # Since that's work, sleep briefly.
    Process.sleep(10)
    port
  end

  test "closing the port kills the process" do
    port = run_muontrap(["./test/do_nothing.test"])

    os_pid = os_pid(port)
    assert_os_pid_running(os_pid)

    Port.close(port)

    wait_for_close_check()
    assert_os_pid_exited(os_pid)
  end

  test "closing the port kills a process that ignores sigterm" do
    port = run_muontrap(["--delay-to-sigkill", "1", "test/ignore_sigterm.test"])

    os_pid = os_pid(port)
    assert_os_pid_running(os_pid)
    Port.close(port)

    wait_for_close_check()
    assert_os_pid_exited(os_pid)
  end

  test "delaying the SIGKILL" do
    port = run_muontrap(["--delay-to-sigkill", "250", "test/ignore_sigterm.test"])

    Process.sleep(10)
    os_pid = os_pid(port)
    assert_os_pid_running(os_pid)
    Port.close(port)

    Process.sleep(100)
    # process should be around for 250ms, so it should be around here.
    assert_os_pid_running(os_pid)

    Process.sleep(200)

    # Now it should be gone
    assert_os_pid_exited(os_pid)
  end

  @project_root Path.expand("..", __DIR__)

  test "README.md version is up to date" do
    app = :proton_stream
    app_version = Application.spec(app, :vsn) |> to_string()
    readme = File.read!(Path.join(@project_root, "README.md"))
    [_, readme_version] = Regex.run(~r/{:#{app}, "(.+)"}/, readme)
    assert Version.match?(app_version, readme_version)
  end
end
