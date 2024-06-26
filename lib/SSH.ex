defmodule SSH do
  @moduledoc """

  SSH streams and SSH and basic SCP functionality

  The librarian SSH module provides SSH streams (see `stream/3`) and
  three protocols over the SSH stream:

  - `run/3`, which runs a command on the remote SSH host.
  - `fetch/3`, which uses the SCP protocol to obtain a remote file,
  - `send/4`, which uses the SCP protocol to send a file to the remote host.

  Note that not all SSH hosts (for example, embedded shells), implement an
  SCP command, so you may not necessarily be able to perform SCP over your
  SSH stream.

  ## Using SSH

  The principles of this library are simple.  You will first want to create
  an SSH connection using the `connect/2` function.  There you will provide
  credentials (or let the system figure out the default credentials).  The
  returned `conn` term can then be passed to the multiple utilities.

  ```elixir
  {:ok, conn} = SSH.connect("some.other.server")
  SSH.run!(conn, "echo hello ssh")  # ==> "hello ssh"
  ```

  ## Using SCP

  This library also provides `send!/4` and `fetch!/3` functions which let you
  perform SCP operations via the SSH streams.

  ```elixir
  {:ok, conn} = SSH.connect("some.other.server")
  SSH.send!(conn, binary_or_filestream, "path/to/destination.file")
  ```

  ```elixir
  {:ok, conn} = SSH.connect("some.other.server")
  SSH.fetch!(conn, "path/to/source.file")
  |> Enum.map(&do_something_with_chunks/1)
  ```

  ### Important

  If you are performing a streaming SCP send, you may only pass a filestream
  or a stream-of-a-filestream into the `send!/3` function.  If you are
  streaming your filestream through other stream operators make sure that the
  total file size remains unchanged.

  ## Bang vs non-bang functions

  As a general rule, if you expect to run a single or series of tasks with
  transient (or no) supervision, for example in a worker task or elixir script
  you should use the bang function and let the task fail, designing your
  supervision accordingly.  This will also potentially let you be lazy about
  system resources such as SSH connections.

  If you expect your SSH task to run as a part of a long-running process
  (for example, checking in on a host and retrieving data), you should use the
  error tuple forms and also be careful about closing your ssh connections
  after use.  Check the [connection labels](#connect/2-labels) documentation
  for a strategy to organize your code around this neatly.

  ## Mocking

  There's a good chance you'll want to mock your SSH commands and responses.
  The `SSH.Api` behaviour module is provided for that purpose.

  ## Logging

  The SSH and related modules interface with Elixir (and Erlang's) logging
  facility.  The default metadata tagged on the message is `ssh: true`; if
  you would like to set it otherwise you can set the `:librarian, :ssh_metadata`
  application environment variable.

  ## Customization

  If you would like to write your own SSH stream handlers that plug in to
  the SSH stream and provide either rudimentary interactivity or early stream
  token processing, you may want to consider implementing a module following
  the `SSH.ModuleApi` behaviour, and initiating your stream as desired.

  ## Limitations

  This library has largely been tested against Linux SSH clients.  Not all
  SSH schemes are amenable to stream processing.  In those cases you should
  implement an ssh client gen_server using erlang's ssh_client, though
  support for this in elixir is planned in the near-term.
  """

  @behaviour SSH.Api

  alias SSH.SCP.Fetch
  alias SSH.SCP.Send

  require Logger

  #############################################################################
  ## generally useful types

  @typedoc "erlang ip4 format, `{byte, byte, byte, byte}`"
  @type ip4 :: :inet.ip4_address()

  @typedoc "connect to a remote is specified using either a domain name or an ip address"
  @type remote :: String.t() | charlist | ip4

  @typedoc "connection reference for the SSH and SCP operations"
  @type conn :: :ssh.connection_ref()

  @typedoc "channel reference for the SSH and SCP operations"
  @type chan :: :ssh.channel_id()

  #############################################################################
  ## connection and stream handling

  @type connect_result :: {:ok, SSH.conn()} | {:error, any}

  @doc """
  initiates an ssh connection with a remote server.

  ### options:

  - `:use_ssh_config` see `SSH.Config`, defaults to `false`.
  - `:global_config_path` see `SSH.Config`.
  - `:user_config_path` see `SSH.Config`.
  - `:user` username to log in as.
  - `:port` port to use to ssh, defaults to 22.
  - `:label` see [labels](#connect/2-labels)
  - `:link` if `true`, links the connection with the calling process.
    Note the calling process *will not* die if the SSH connection is
    closed using `close/1`.

  and other SSH options.  Some conversions between ssh options and SSH.connect
  options:

  | ssh commandline option        | SSH library option            |
  | ----------------------------- | ----------------------------- |
  | `-o StrictHostKeyChecking=no` | `silently_accept_hosts: true` |
  | `-q`                          | `quiet_mode: true`            |
  | `-o ConnectTimeout=time`      | `connect_timeout: time_in_ms` |
  | `-i pemfile`                  | `identity: file`              |

  also consult documentation on client options in the [erlang docs](http://erlang.org/doc/man/ssh.html#type-client_options)

  ### labels:

  You can label your ssh connection to provide a side-channel for
  correctly closing the connection pid.  This is most useful in
  the context of `with/1` blocks.  As an example, the following
  code works:

  ```elixir
  def run_ssh_tasks do
    with {:ok, conn} <- SSH.connect("some_host", label: :this_task),
         {:ok, _result1, 0} <- SSH.run(conn, "some_command"),
         {:ok, result2, 0} <- SSH.run(conn, "some other command") do
      {:ok, result1}
    end
  after
    SSH.close(:this_task)
  end
  ```

  Some important points:
  - If you are wrangling multiple SSH sessions, please use unique connection
    labels.
  - The ssh connection label is stored in the process dictionary, so the label
    will not be valid across process boundaries.
  - If the ssh connection failed in the first place, the tagged close will
    return an error tuple.  In the example, this will be silent.
  """
  @impl true
  @spec connect(remote, keyword) :: connect_result
  def connect(remote, options \\ []) do
    # default to the charlist version.
    options1 = SSH.Config.assemble(remote, options)
    options2 = Keyword.drop(options1, [:port, :host_name, :identity])

    # attempt to resolve the identity issue here.  Maybe it will go into SSH.Config?
    options3 =
      if identity = options1[:identity] do
        # append our ClientIdentity handler.
        [{:key_cb, {SSH.ClientIdentity, identity: identity}} | options2]
      else
        options2
      end

    options1[:host_name]
    |> :ssh.connect(options1[:port], options3)
    |> do_link(options[:link])
    |> stash_label(options[:label])
  end

  @spec do_link({:ok, conn} | {:error, any}, boolean | nil) :: {:ok, conn} | {:error, any}
  defp do_link({:ok, conn}, should_link?) do
    if should_link?, do: Process.link(conn)
    {:ok, conn}
  end

  defp do_link(any, _), do: any

  @spec stash_label({:ok, conn} | {:error, any}, term) :: {:ok, conn} | {:error, any} | no_return
  defp stash_label(res, nil), do: res

  defp stash_label(_, pid) when is_pid(pid) do
    raise ArgumentError, "you can't make a pid label for an SSH connection."
  end

  defp stash_label(res = {:ok, conn}, label) do
    new_labels =
      :"$ssh"
      |> Process.get()
      |> case do
        nil -> %{label => conn}
        map -> Map.put(map, label, conn)
      end

    Process.put(:"$ssh", new_labels)
    res
  end

  defp stash_label(res, _), do: res

  @doc """
  like `connect/2` but raises with a ConnectionError instead of emitting an error tuple.
  """
  @impl true
  @spec connect!(remote, keyword) :: conn | no_return
  def connect!(remote, options \\ []) do
    case connect(remote, options) do
      {:ok, conn} ->
        conn

      {:error, message} ->
        host = if is_tuple(remote), do: :inet.ntoa(remote), else: remote
        raise SSH.ConnectionError, "error connecting to #{host}: #{error_fmt(message)}"
    end
  end

  @doc """
  creates an SSH stream struct as an ok tuple or error tuple.

  ## Options

  - `{iostream, redirect}`:  `iostream` may be either `:stdout` or `:stderr`.  `redirect`
    may be one of the following:
    - `:stream` sends the data to the stream.
    - `:stdout` sends the data to the `group_leader` stdout.
    - `:stderr` sends the data to the standard error io stream.
    - `:silent` deletes all of the data.
    - `:raw` sends the data to the stream tagged with source information as
      either `{:stdout, data}` or `{:stderr, data}`, as appropriate.
    - `{:file, path}` sends the data to a new or existing file at the provided
      path.
    - `fun/1` processes the data via the function, with the output flat-mapped
      into the stream. this means that the results of `fun/1` should be lists,
      with an empty list sending nothing into the stream.
    - `fun/2` is like `fun/1` except the stream struct is passed as the second
      parameter.  The output of `fun/2` should take the shape
      `{flat_map_results, modified_stream}`.  You may use the `:data` field of
      the stream struct to store arbitrary data; and a value of `nil` indicates
      that it has been unused.
  - `{:stream_control_messages, boolean}`: should the stream control messages `:eof`, or `{:retval, integer}`
    be sent to the stream?
  - `module: {mod, init}`,  The stream is operated using an module with behaviour `SSH.ModuleApi`
  - `data_timeout: timeout`, how long to wait between packets till we send a timeout event.
  """
  @spec stream(conn, String.t(), keyword) :: {:ok, SSH.Stream.t()} | {:error, String.t()}
  def stream(conn, cmd, options \\ []) do
    SSH.Stream.__build__(conn, [{:cmd, cmd} | options])
  end

  @doc """
  like `stream/2`, except raises on an error instead of an error tuple.
  """
  @spec stream!(conn, String.t(), keyword) :: SSH.Stream.t() | no_return
  def stream!(conn, cmd, options \\ []) do
    case stream(conn, cmd, options) do
      {:ok, stream} ->
        stream

      {:error, error} ->
        raise SSH.StreamError, message: "error creating ssh stream: #{error_fmt(error)}"
    end
  end

  @doc """
  closes the ssh connection.

  Typically you will pass the connection reference to this function.  If your
  connection is contained to its own transient task process, you may not need
  to call this function as the ssh client library will detect that the process
  has ended and clean up after you.

  In some cases, you may want to be able to close a connection out-of-band.
  In this case, you may label your connection and use the label to perform
  the close operation.  See [labels](#connect/2-labels)
  """
  @impl true
  @spec close(conn | term) :: :ok | {:error, String.t()}
  def close(conn) when is_pid(conn), do: :ssh.close(conn)

  def close(label) do
    case Process.get(:"$ssh") do
      map = %{^label => pid} ->
        Process.put(:"$ssh", Map.delete(map, label))
        :ssh.close(pid)

      _ ->
        {:error, "ssh connection with label #{label} not found"}
    end
  end

  #############################################################################
  ## SSH MODE: running

  @typedoc "unix-style return codes for ssh-executed functions"
  @type retval :: 0..255

  @type run_content :: iodata | {String.t(), String.t()}

  @type run_result :: {:ok, run_content, retval} | {:error, term}

  @doc """
  runs a command on the remote host.  Typically returns `{:ok, result, retval}` where
  `retval` is the unix return value from the range `0..255`.

  the `result` value is governed by the passed options, but defaults to a string. of
  the run value.

  ### Options

  - `{iostream, redirect}`:  `iostream` may be either `:stdout` or `:stderr`.  `redirect`
    may be one of the following:
    - `:stream` sends the data to the stream.
    - `:stdout` sends the data to the `group_leader` stdout.
    - `:stderr` sends the data to the standard error io stream.
    - `:silent` deletes all of the data.
    - `:raw` sends the data to the stream tagged with source information as either
      `{:stdout, data}` or `{:stderr, data}`, as appropriate.
    - `{:file, path}` sends the data to a new or existing file at the provided path.
    - `fun/1` processes the data via the function, with the output flat-mapped
      into the stream. this means that the results of `fun/1` should be lists,
      with an empty list sending nothing into the stream.
    - `fun/2` is like `fun/1` except the stream struct is passed as the second
      parameter.  The output of `fun/2` should take the shape `{flat_map_results, modified_stream}`.
      You may use the `:data` field of the stream struct to store arbitrary
      data; and a value of `nil` indicates that it has been unused.
  - `{:tty, true | <options>}`: register the connection as a tty connection.
    Note this changes the default behavior to send the output to group leader
    stdout instead of to the result, but this is overridable with the iostream
    redirect above.  For options, see `:ssh_client_connection.ptty_alloc/4`
  - `{:env, <env list>}`: a list of environment variables to be passed.  NB: typically
    environment variables are filtered by the host environment.
  - `{:dir, path}`: changes directory to `path` and then runs the command
  - `{:as, :binary}` (default): outputs result as a binary
  - `{:as, :iolist}`: outputs result as an iolist
  - `{:as, :tuple}`: result takes the shape of the tuple `{stdout_binary, stderr_binary}`
    note that this mode will override any other redirection selected.

  ### Example:

  ```elixir
  SSH.run(conn, "hostname")  # ==> {:ok, "hostname_of_remote\\n", 0}

  SSH.run(conn, "some_program", stderr: :silent) # ==> similar to running "some_program 2>/dev/null"

  SSH.run(conn, "some_program", stderr: :stream) # ==> similar to running "some_program 2>&1"

  SSH.run(conn, "some_program", stdout: :silent, stderr: :stream) # ==> only capture standard error
  ```

  """
  @impl true
  @spec run(conn, String.t(), keyword) :: run_result
  def run(conn, cmd, options \\ []) do
    options! = Keyword.put(options, :stream_control_messages, true)
    {cmd!, options!} = adjust_run(cmd, options!)

    with {:ok, stream} <- SSH.Stream.__build__(conn, [{:cmd, cmd!} | options!]) do
      stream
      |> Enum.reduce({:error, [], nil}, &consume/2)
      |> normalize_output(options!)
    end
  end

  @doc """
  like `run/3` except raises on errors instead of returning an error tuple.

  Note that by default this raises in the case that the SSH connection fails
  AND in the case that the remote command returns non-zero.
  """
  @impl true
  @spec run!(conn, String.t(), keyword) :: run_content | no_return
  def run!(conn, cmd, options \\ []) do
    case run(conn, cmd, options ++ [as: :tuple]) do
      {:ok, {result, stderr}, 0} ->
        if options[:io_tuple], do: {result, stderr}, else: result

      {:ok, result, 0} ->
        result

      {:ok, {_, stderr}, retcode} ->
        raise SSH.RunError, "command #{cmd} errored with retcode #{retcode}: #{stderr}"

      {:ok, _result, retcode} ->
        raise SSH.RunError, "command #{cmd} errored with retcode #{retcode}"

      error ->
        raise SSH.StreamError, "ssh errored with #{error_fmt(error)}"
    end
  end

  defp consume(str, {status, list, retval}) when is_binary(str),
    do: {status, [list | str], retval}

  defp consume(token = {a, b}, {status, list, retval}) when is_atom(a) and is_binary(b) do
    {status, [token | list], retval}
  end

  defp consume(:eof, {_any, list, retval}), do: {:ok, list, retval}
  defp consume({:error, reason}, {_status, list, _any}), do: {:error, list, reason}
  defp consume({:retval, retval}, {status, list, _any}), do: {status, list, retval}

  defp normalize_output({a, list, b}, options) do
    case options[:as] do
      nil ->
        {a, :erlang.iolist_to_binary(list), b}

      :binary ->
        {a, :erlang.iolist_to_binary(list), b}

      :iolist ->
        {a, list, b}

      :tuple ->
        tuple_map =
          list
          |> Enum.reverse()
          |> Enum.group_by(fn {key, _} -> key end, fn {_, value} -> value end)

        result = {
          :erlang.iolist_to_binary(tuple_map[:stdout] || []),
          :erlang.iolist_to_binary(tuple_map[:stderr] || [])
        }

        {a, result, b}
    end
  end

  defp normalize_output(error, _options), do: error

  defp adjust_run(cmd, options) do
    # drop any naked as: :tuple pairs.
    options! = options -- [as: :tuple]

    dir = options![:dir]

    if dir do
      {"cd #{dir}; " <> cmd, refactor(options!)}
    else
      {cmd, refactor(options!)}
    end
  end

  defp refactor(options) do
    if options[:io_tuple] do
      options
      |> Keyword.drop([:stdout, :stderr, :io_tuple, :as])
      |> Keyword.merge(stdout: :raw, stderr: :raw, as: :tuple)
    else
      options
    end
  end

  #############################################################################
  ## SCP MODE: sending

  @type send_result :: :ok | {:error, term}

  @type filestreams ::
          %Stream{enum: %File.Stream{}}
          | %File.Stream{}

  @doc """
  sends binary content to the remote host.

  Under the hood, this uses the scp protocol to transfer files.

  Protocol is as follows:
  - execute `scp` remotely in the undocumented `-t <destination>` mode
  - send a control string `"C0<perms> <size> <filename>"`
  - wait for single zero byte
  - send the binary data + terminating zero
  - wait for single zero byte
  - send `EOF`

  The perms term should be in octal, and the filename should be rootless.

  options:
  - `:permissions` - sets unix-style permissions on the file.  Defaults to `0o644`

  Example:
  ```
  SSH.send(conn, "foo", "path/to/desired/file")
  ```
  """
  @impl true
  @spec send(conn, iodata | filestreams, Path.t(), keyword) :: send_result
  def send(conn, stream, remote_file, options \\ [])

  def send(conn, src_stream = %_{}, remote_file, options) do
    size = find_size_of(src_stream)
    perms = Keyword.get(options, :permissions, 0o644)

    file_id = Path.basename(remote_file)

    case SSH.Stream.__build__(conn,
           cmd: "scp -t #{remote_file}",
           module: {SSH.SCP.Stream, {Path.basename(remote_file), size, perms}},
           data_timeout: 500,
           prerun_fn:
             &SSH.SCP.Stream.scp_init(
               &1,
               &2,
               "C0#{Integer.to_string(perms, 8)} #{size} #{file_id}\n"
             ),
           on_finish: &Function.identity/1,
           on_stream_done: &SSH.SCP.Stream.on_stream_done/1
         ) do
      {:ok, ssh_stream} ->
        src_stream
        |> Enum.into(ssh_stream)
        |> Stream.run()

      error ->
        error
    end
  end

  def send(conn, content, remote_file, options) do
    perms = Keyword.get(options, :permissions, 0o644)
    filename = Path.basename(remote_file)
    initializer = {filename, content, perms}

    case SSH.Stream.__build__(conn,
           cmd: "scp -t #{remote_file}",
           module: {Send, initializer},
           data_timeout: 500
         ) do
      {:ok, stream} ->
        Enum.reduce(stream, :ok, &Send.reducer/2)

      error ->
        error
    end
  end

  defp find_size_of(%Stream{enum: fstream = %File.Stream{}}) do
    find_size_of(fstream)
  end

  defp find_size_of(fstream = %File.Stream{}) do
    case File.stat(fstream.path) do
      {:ok, stat} -> stat.size
      _ -> raise SSH.SCP.Error, "error getting file size for #{fstream.path}"
    end
  end

  @doc """
  like `send/4`, except raises on errors, instead of returning an error tuple.
  """
  @impl true
  @spec send!(conn, iodata, Path.t()) :: :ok | no_return
  @spec send!(conn, iodata, Path.t(), keyword) :: :ok | no_return
  def send!(conn, content, remote_file, options \\ []) do
    case send(conn, content, remote_file, options) do
      :ok ->
        :ok

      {:error, message} ->
        raise SSH.SCP.Error, "error executing SCP send: #{error_fmt(message)}"
    end
  end

  #############################################################################
  ## SCP MODE: fetching

  @type fetch_result :: {:ok, binary} | {:error, term}

  @doc """
  retrieves a binary file from the remote host.

  Under the hood, this uses the scp protocol to transfer files.

  The SCP protocol is as follows:
  - execute `scp` remotely in the undocumented `-f <source>` mode
  - send a single zero byte to initiate the conversation
  - wait for a control string `"C0<perms> <size> <filename>"`
  - send a single zero byte
  - wait for the binary data + terminating zero
  - send a single zero byte

  The perms term should be in octal, and the filename should be rootless.

  Example:
  ```
  SSH.fetch(conn, "path/to/desired/file")
  ```
  """
  @impl true
  @spec fetch(conn, Path.t(), keyword) :: fetch_result
  def fetch(conn, remote_file, _options \\ []) do
    with {:ok, stream} <-
           SSH.Stream.__build__(conn,
             cmd: "scp -f #{remote_file}",
             module: {Fetch, :ok},
             data_timeout: 500
           ) do
      Enum.reduce(stream, :ok, &Fetch.reducer/2)
    end
  end

  @doc """
  like `fetch/3` except raises instead of emitting an error tuple.
  """
  @impl true
  @spec fetch!(conn, Path.t(), keyword) :: binary | no_return
  def fetch!(conn, remote_file, options \\ []) do
    case fetch(conn, remote_file, options) do
      {:ok, result} ->
        result

      {:error, message} ->
        raise SSH.SCP.Error, "error executing SCP send: #{error_fmt(message)}"
    end
  end

  defp error_fmt(atom) when is_atom(atom), do: atom
  defp error_fmt(binary) when is_binary(binary), do: binary
  defp error_fmt(any), do: inspect(any)
end

defmodule SSH.StreamError do
  defexception [:message]
end

defmodule SSH.RunError do
  defexception [:message]
end
