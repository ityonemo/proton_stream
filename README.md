# ProtonStream

[![Hex version](https://img.shields.io/hexpm/v/proton_stream.svg "Hex version")](https://hex.pm/packages/proton_stream)
[![API docs](https://img.shields.io/hexpm/v/proton_stream.svg?label=hexdocs "API docs")](https://hexdocs.pm/proton_stream/ProtonStream.html)
[![CI](https://github.com/ityonemo/proton_stream/actions/workflows/ci.yml/badge.svg)](https://github.com/ityonemo/proton_stream/actions/workflows/ci.yml)
[![REUSE status](https://api.reuse.software/badge/github.com/ityonemo/proton_stream)](https://api.reuse.software/info/github.com/ityonemo/proton_stream)

A streaming API for OS processes that mirrors Elixir's `Port` module. ProtonStream
keeps programs, daemons, and applications launched from Erlang and Elixir contained
and well-behaved. This lightweight library kills OS processes if the Elixir process
running them crashes and if you're running on Linux, it can use cgroups to prevent
many other shenanigans.

Some features:

* Streaming API that mirrors Elixir's `Port` module
* Bidirectional communication with stdin/stdout/stderr
* Set `cgroup` controls like thresholds on memory and CPU utilization
* Start OS processes as a different user or group
* Send SIGKILL to processes that aren't responsive to SIGTERM
* With `cgroups`, ensure that all children of launched processes have been killed too

## TL;DR

Add `proton_stream` to your project's `mix.exs` dependency list:

```elixir
def deps do
  [
    {:proton_stream, "~> 1.0"}
  ]
end
```

## Streaming API

The primary API is `ProtonStream.open/3` which starts a GenServer managing an OS
process. The calling process becomes the "owner" and receives messages:

```elixir
{:ok, ps} = ProtonStream.open("cat", [])

# Send data to stdin
send(ps, {self(), {:command, "hello"}})

# Receive stdout
receive do
  {^ps, {:data, data}} -> IO.puts("Got: #{data}")
end

# Close when done
send(ps, {self(), :close})
```

### Messages

**Messages TO ProtonStream (from owner):**

* `{pid, {:command, binary}}` - send data to child's stdin
* `{pid, :close}` - close the port
* `{pid, {:connect, new_pid}}` - transfer ownership to another process

**Messages FROM ProtonStream (to owner):**

* `{pid, {:data, data}}` - stdout from child process
* `{pid, {:error, data}}` - stderr from child process
* `{pid, :closed}` - reply to close request
* `{pid, :connected}` - reply to connect request
* `{:EXIT, pid, reason}` - process termination (when trapping exits)

### Bidirectional Communication

ProtonStream supports full bidirectional communication:

```elixir
{:ok, ps} = ProtonStream.open("bc", ["-q"])

send(ps, {self(), {:command, "2 + 2\n"}})
receive do
  {^ps, {:data, "4\n"}} -> :ok
end

send(ps, {self(), {:command, "10 * 10\n"}})
receive do
  {^ps, {:data, "100\n"}} -> :ok
end
```

## Blocking API

For simple one-shot commands, use `ProtonStream.cmd/3` as a `System.cmd/3` replacement:

```elixir
iex> ProtonStream.cmd("echo", ["hello"])
{"hello\n", 0}
```

## FAQ

### How do I watch stdout?

Use `ProtonStream.open/3` and receive `{pid, {:data, data}}` messages:

```elixir
{:ok, ps} = ProtonStream.open("my_program", [])

# In a receive loop or GenServer handle_info:
receive do
  {^ps, {:data, data}} -> IO.write(data)
  {^ps, {:error, data}} -> IO.write(:stderr, data)
end
```

### How do I send input to stdin?

Use the streaming API:

```elixir
{:ok, ps} = ProtonStream.open("cat", [])
send(ps, {self(), {:command, "hello world\n"}})
```

### How do I stop a ProtonStream process?

Send a close message:

```elixir
send(ps, {self(), :close})
```

## Background

The Erlang VM's port interface lets Elixir applications run external programs.
This is important since it's not practical to rewrite everything in Elixir.
Plus, if the program is long running like a daemon or a server, you use Elixir
to supervise it and restart it on crashes. The catch is that the Erlang VM
expects port processes to be well-behaved. As you'd expect, many useful programs
don't quite meet the Erlang VM's expectations.

For example, let's say that you want to monitor a network connection and decide
that `ping` is the right tool. Here's how you could start `ping` in a process.

```elixir
iex> pid = spawn(fn -> System.cmd("ping", ["-i", "5", "localhost"], into: IO.stream(:stdio, :line)) end)
#PID<0.6116.0>
PING localhost (127.0.0.1): 56 data bytes
64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.032 ms
64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=0.077 ms
```

Now exit the Elixir process:

```elixir
iex> Process.exit(pid, :oops)
true
iex> :os.cmd(~c"ps -ef | grep ping") |> IO.puts
  501 38820 38587   0  9:26PM ??         0:00.02 /sbin/ping -i 5 localhost
```

As you can tell, `ping` is still running after the exit. The reason is that
`ping` doesn't pay attention to `stdin` and doesn't notice the Erlang VM closing
it to signal that it should exit.

This is just one of the problems that `proton_stream` fixes.

## Containment with cgroups

Even if you don't make use of any cgroup controller features, having your port
process contained can be useful just to make sure that everything is cleaned
up on exit including any subprocesses.

To set this up, first create a cgroup with appropriate permissions:

```bash
sudo cgcreate -a $(whoami) -g memory,cpu:mycgroup
```

Then use the cgroup options:

```elixir
{:ok, ps} = ProtonStream.open("spawning_program", [],
  cgroup_controllers: ["cpu"],
  cgroup_base: "mycgroup"
)
```

On any error or if the Erlang VM closes the port or if `spawning_program` exits,
`proton_stream` will kill all OS processes in cgroup.

### Limit memory

```elixir
ProtonStream.open("memory_hog", [],
  cgroup_controllers: ["memory"],
  cgroup_base: "mycgroup",
  cgroup_sets: [{"memory", "memory.limit_in_bytes", "268435456"}]
)
```

### Limit CPU

```elixir
ProtonStream.open("cpu_hog", [],
  cgroup_controllers: ["cpu"],
  cgroup_base: "mycgroup",
  cgroup_sets: [
    {"cpu", "cpu.cfs_period_us", "100000"},
    {"cpu", "cpu.cfs_quota_us", "50000"}
  ]
)
```

## stdio flow control

ProtonStream implements flow control to prevent the program's output from
overwhelming the Elixir process's mailbox. The `:stdio_window` option specifies
the maximum number of unacknowledged bytes allowed (default 10 KB).

## Development

To run tests, install cgroup-tools (`cgcreate`, `cgget`):

```sh
sudo cgcreate -a $(whoami) -g memory,cpu:proton_stream_test
mix test
```

## License

All original source code in this project is licensed under Apache-2.0.

Additionally, this project follows the [REUSE recommendations](https://reuse.software)
and labels so that licensing and copyright are clear at the file level.

Exceptions to Apache-2.0 licensing are:

* Configuration and data files are licensed under CC0-1.0
* Documentation is CC-BY-4.0
