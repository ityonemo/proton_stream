# SPDX-FileCopyrightText: 2018 Frank Hunleth
# SPDX-FileCopyrightText: 2023 Ben Youngblood
# SPDX-FileCopyrightText: 2023 Eric Rauer
# SPDX-FileCopyrightText: 2023 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0

defmodule ProtonStream.Options do
  @moduledoc """
  Validate and normalize the options passed to `ProtonStream.open/3`.

  This module is generally not called directly, but it's likely
  the source of exceptions if any options aren't quite right. Call `validate/4` directly to
  debug or check options without invoking a command.
  """

  @typedoc """
  The following fields are always present:

  * `:command` - the command to run
  * `:args` - a list of arguments to the command

  The next fields are optional:

  * `:cd`
  * `:arg0`
  * `:stderr_to_stdout`
  * `:capture_stderr_only`
  * `:parallelism`
  * `:env`
  * `:stdio_window`
  * `:cgroup_controllers`
  * `:cgroup_path`
  * `:cgroup_base`
  * `:delay_to_sigkill`
  * `:cgroup_sets`
  * `:uid`
  * `:gid`

  """
  @type t() :: map()

  @doc """
  Validate options and normalize them for invoking commands.
  """
  @spec validate(:stream, binary(), [binary()], keyword()) :: t()
  def validate(:stream, cmd, args, opts) do
    assert_no_null_byte!(cmd)

    if !Enum.all?(args, &is_binary/1) do
      raise ArgumentError, "all arguments for ProtonStream.open/3 must be binaries"
    end

    abs_command = System.find_executable(cmd) || :erlang.error(:enoent, [cmd, args, opts])

    validate_options(abs_command, args, opts)
    |> resolve_cgroup_path()
  end

  defp resolve_cgroup_path(%{cgroup_path: _path, cgroup_base: _base}) do
    raise ArgumentError, "cannot specify both a cgroup_path and a cgroup_base"
  end

  defp resolve_cgroup_path(%{cgroup_base: base} = options) do
    # Create a random subfolder for this invocation
    Map.put(options, :cgroup_path, Path.join(base, random_string()))
  end

  defp resolve_cgroup_path(other), do: other

  # Thanks https://github.com/danhper/elixir-temp/blob/master/lib/temp.ex
  defp random_string() do
    Integer.to_string(:rand.uniform(0x100000000), 36) |> String.downcase()
  end

  defp validate_options(cmd, args, opts) do
    Enum.reduce(
      opts,
      %{command: cmd, args: args},
      &validate_option(&1, &2)
    )
  end

  defp validate_option({:cd, bin}, opts) when is_binary(bin), do: Map.put(opts, :cd, bin)

  defp validate_option({:arg0, bin}, opts) when is_binary(bin),
    do: Map.put(opts, :arg0, bin)

  defp validate_option({:stderr_to_stdout, bool}, opts) when is_boolean(bool),
    do: Map.put(opts, :stderr_to_stdout, bool)

  defp validate_option({:capture_stderr_only, bool}, opts) when is_boolean(bool),
    do: Map.put(opts, :capture_stderr_only, bool)

  defp validate_option({:parallelism, bool}, opts) when is_boolean(bool),
    do: Map.put(opts, :parallelism, bool)

  defp validate_option({:env, enum}, opts),
    do: Map.put(opts, :env, validate_env(enum))

  defp validate_option({:stdio_window, count}, opts) when is_integer(count),
    do: Map.put(opts, :stdio_window, count)

  defp validate_option({:cgroup_controllers, controllers}, opts) when is_list(controllers),
    do: Map.put(opts, :cgroup_controllers, controllers)

  defp validate_option({:cgroup_path, path}, opts) when is_binary(path) do
    Map.put(opts, :cgroup_path, path)
  end

  defp validate_option({:cgroup_base, path}, opts) when is_binary(path) do
    Map.put(opts, :cgroup_base, path)
  end

  defp validate_option({:delay_to_sigkill, delay}, opts) when is_integer(delay),
    do: Map.put(opts, :delay_to_sigkill, delay)

  defp validate_option({:cgroup_sets, sets}, opts) when is_list(sets),
    do: Map.put(opts, :cgroup_sets, sets)

  defp validate_option({:uid, id}, opts) when is_integer(id) or is_binary(id),
    do: Map.put(opts, :uid, id)

  defp validate_option({:gid, id}, opts) when is_integer(id) or is_binary(id),
    do: Map.put(opts, :gid, id)

  defp validate_option({key, val}, _opts),
    do: raise(ArgumentError, "invalid option #{inspect(key)} with value #{inspect(val)}")

  defp validate_env(enum) do
    Enum.map(enum, fn
      {k, nil} ->
        {String.to_charlist(k), false}

      {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}

      other ->
        raise ArgumentError, "invalid environment key-value #{inspect(other)}"
    end)
  end

  defp assert_no_null_byte!(binary) do
    case :binary.match(binary, "\0") do
      {_, _} ->
        raise ArgumentError,
              "cannot execute ProtonStream.open/3 for program with null byte, got: #{inspect(binary)}"

      :nomatch ->
        :ok
    end
  end
end
