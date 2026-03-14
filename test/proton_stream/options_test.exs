# SPDX-FileCopyrightText: 2018 Frank Hunleth
# SPDX-FileCopyrightText: 2023 Ben Youngblood
# SPDX-FileCopyrightText: 2023 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0

defmodule ProtonStream.OptionsTest do
  use ProtonStreamTest.Case

  alias ProtonStream.Options

  test "creates random cgroup path when asked" do
    options = Options.validate(:stream, "echo", [], cgroup_base: "base")
    assert Map.has_key?(options, :cgroup_path)

    ["base", other] = String.split(options.cgroup_path, "/")
    assert byte_size(other) > 4
  end

  test "disallow both cgroup_path and cgroup_base" do
    assert_raise ArgumentError, fn ->
      Options.validate(:stream, "echo", [], cgroup_base: "base", cgroup_path: "path")
    end
  end

  test "validates arguments" do
    assert_raise ArgumentError, fn ->
      Options.validate(:stream, "echo", [~c"not_a_binary"], [])
    end

    assert_raise ArgumentError, fn ->
      Options.validate(:stream, "why\0would_someone_do_this", [], [])
    end
  end

  test "rejects invalid options" do
    assert_raise ArgumentError, fn ->
      Options.validate(:stream, "echo", [], into: "")
    end

    assert_raise ArgumentError, fn ->
      Options.validate(:stream, "echo", [], timeout: 1000)
    end
  end

  test "common options work" do
    input = [
      cd: "path",
      arg0: "arg0",
      stderr_to_stdout: true,
      capture_stderr_only: true,
      parallelism: true,
      uid: 5,
      gid: "bill",
      delay_to_sigkill: 1,
      stdio_window: 1024,
      env: [{"KEY", "VALUE"}, {"KEY2", "VALUE2"}],
      cgroup_controllers: ["memory", "cpu"],
      cgroup_base: "base",
      cgroup_sets: [{"memory", "memory.limit_in_bytes", "268435456"}]
    ]

    options = Options.validate(:stream, "echo", [], input)

    assert Map.get(options, :cd) == "path"
    assert Map.get(options, :arg0) == "arg0"
    assert Map.get(options, :stderr_to_stdout) == true
    assert Map.get(options, :capture_stderr_only) == true
    assert Map.get(options, :parallelism) == true
    assert Map.get(options, :uid) == 5
    assert Map.get(options, :gid) == "bill"
    assert Map.get(options, :delay_to_sigkill) == 1
    assert Map.get(options, :stdio_window) == 1024
    assert Map.get(options, :env) == [{~c"KEY", ~c"VALUE"}, {~c"KEY2", ~c"VALUE2"}]
    assert Map.get(options, :cgroup_controllers) == ["memory", "cpu"]
    assert Map.get(options, :cgroup_base) == "base"
    assert Map.get(options, :cgroup_sets) == [{"memory", "memory.limit_in_bytes", "268435456"}]
  end
end
