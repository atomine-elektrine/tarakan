defmodule TarakanWeb.GitHTTP.Service do
  @moduledoc """
  The smart-HTTP protocol core: ref advertisement and the stateless RPCs.

  RPC bodies stream to a `git upload-pack`/`git receive-pack` subprocess
  through an Erlang port and the response streams back chunked. Ports cannot
  half-close stdin, but that is fine here: stateless-rpc requests are
  self-delimiting (an upload-pack request ends with a flush/`done` pkt; a
  receive-pack pack stream carries its own object count and trailing hash),
  so git writes its response and exits without waiting for EOF. A hard
  wall-clock deadline closes the port if a malformed request ever leaves git
  waiting on stdin.
  """

  import Plug.Conn

  alias Tarakan.Git.Local
  alias Tarakan.HostedRepositories.Storage

  require Logger

  @read_chunk_bytes 65_536
  # An upload-pack request is pure negotiation (wants/haves) and stays tiny;
  # only receive-pack carries a pack file.
  @max_upload_pack_request_bytes 10 * 1_024 * 1_024
  @upload_pack_timeout_ms :timer.seconds(60)
  @receive_pack_timeout_ms :timer.seconds(300)

  @doc "GET /:owner/:name.git/info/refs?service=…"
  def advertise_refs(conn, repository, service) do
    dir = Storage.dir(repository)

    case Local.run(dir, [service_subcommand(service), "--stateless-rpc", "--advertise-refs", "."],
           extra_env: protocol_env(conn)
         ) do
      {:ok, output} ->
        body = [pkt_line("# service=#{service}\n"), "0000", output]

        # Exact content type, no charset parameter: git validates this
        # header to distinguish smart from dumb HTTP.
        conn
        |> put_resp_header("content-type", "application/x-#{service}-advertisement")
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, body)
        |> halt()

      {:error, reason} ->
        Logger.warning(
          "git advertise-refs failed for repository #{repository.id}: #{inspect(reason)}"
        )

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(500, "unavailable")
        |> halt()
    end
  end

  @doc "POST /:owner/:name.git/git-upload-pack | git-receive-pack"
  def rpc(conn, repository, service, scope) do
    with :ok <- validate_content_type(conn, service),
         {:ok, decoder} <- body_decoder(conn) do
      run_rpc(conn, repository, service, scope, decoder)
    else
      {:error, status, message} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(status, message)
        |> halt()
    end
  end

  defp run_rpc(conn, repository, service, scope, decoder) do
    dir = Storage.dir(repository)
    deadline = System.monotonic_time(:millisecond) + timeout_ms(service)

    port =
      Port.open(
        {:spawn_executable, git_executable()},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: [service_subcommand(service), "--stateless-rpc", dir],
          env: port_env(conn)
        ]
      )

    try do
      case forward_request_body(conn, port, decoder, request_cap(service), deadline) do
        {:ok, conn} ->
          conn =
            conn
            |> put_resp_header("content-type", "application/x-#{service}-result")
            |> put_resp_header("cache-control", "no-cache")
            |> send_chunked(200)

          case stream_response(conn, port, deadline) do
            {:ok, conn, exit_status} ->
              if exit_status == 0 and service == "git-receive-pack" do
                after_receive_pack(repository, scope)
              end

              halt(conn)

            {:client_closed, conn} ->
              halt(conn)
          end

        {:error, status, message} ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(status, message)
          |> halt()
      end
    after
      close_port(port)
    end
  end

  # ── Request streaming ────────────────────────────────────────────────

  defp forward_request_body(conn, port, decoder, cap_bytes, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, 408, "request timed out"}
    else
      case read_body(conn, length: @read_chunk_bytes, read_length: @read_chunk_bytes) do
        {tag, data, conn} when tag in [:ok, :more] ->
          with {:ok, inflated, decoder} <- decode_chunk(decoder, data),
               :ok <- within_cap(decoder, cap_bytes) do
            if inflated != "", do: Port.command(port, inflated)

            case tag do
              :ok -> {:ok, conn}
              :more -> forward_request_body(conn, port, decoder, cap_bytes, deadline)
            end
          else
            {:error, :request_too_large} -> {:error, 413, "request too large"}
            {:error, :invalid_encoding} -> {:error, 400, "invalid request encoding"}
          end

        {:error, _reason} ->
          {:error, 400, "invalid request body"}
      end
    end
  end

  # The decoder tracks both wire bytes and inflated bytes so a gzip bomb
  # trips the cap exactly like an oversized plain body.
  defp body_decoder(conn) do
    case get_req_header(conn, "content-encoding") do
      [] ->
        {:ok, %{zstream: nil, total: 0}}

      ["gzip"] ->
        zstream = :zlib.open()
        # 31 = 15 window bits + 16 for the gzip header format.
        :ok = :zlib.inflateInit(zstream, 31)
        {:ok, %{zstream: zstream, total: 0}}

      _unsupported ->
        {:error, 415, "unsupported content encoding"}
    end
  end

  defp decode_chunk(%{zstream: nil} = decoder, data) do
    {:ok, data, %{decoder | total: decoder.total + byte_size(data)}}
  end

  defp decode_chunk(%{zstream: zstream} = decoder, data) do
    inflated = zstream |> :zlib.inflate(data) |> IO.iodata_to_binary()
    {:ok, inflated, %{decoder | total: decoder.total + byte_size(inflated)}}
  rescue
    _error -> {:error, :invalid_encoding}
  end

  defp within_cap(%{total: total}, cap_bytes) when total <= cap_bytes, do: :ok
  defp within_cap(_decoder, _cap_bytes), do: {:error, :request_too_large}

  # ── Response streaming ───────────────────────────────────────────────

  defp stream_response(conn, port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        case chunk(conn, data) do
          {:ok, conn} -> stream_response(conn, port, deadline)
          {:error, :closed} -> {:client_closed, conn}
        end

      {^port, {:exit_status, status}} ->
        if status != 0 do
          Logger.warning("git rpc subprocess exited with status #{status}")
        end

        {:ok, conn, status}
    after
      remaining ->
        Logger.warning("git rpc timed out; closing subprocess")
        {:client_closed, conn}
    end
  end

  # ── Post-receive (best-effort, never blocks the protocol response) ──

  defp after_receive_pack(repository, scope) do
    if synchronous_post_receive?() do
      Tarakan.HostedRepositories.PostReceive.run(repository, scope)
    else
      Task.Supervisor.start_child(Tarakan.TaskSupervisor, fn ->
        Tarakan.HostedRepositories.PostReceive.run(repository, scope)
      end)
    end

    :ok
  rescue
    _error -> :ok
  end

  defp synchronous_post_receive? do
    :tarakan
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:synchronous_post_receive, false)
  end

  # ── Plumbing ─────────────────────────────────────────────────────────

  defp validate_content_type(conn, service) do
    expected = "application/x-#{service}-request"

    case get_req_header(conn, "content-type") do
      [^expected | _rest] ->
        :ok

      [content_type | _rest] ->
        if String.starts_with?(content_type, expected <> ";") do
          :ok
        else
          {:error, 415, "expected #{expected}"}
        end

      [] ->
        {:error, 415, "expected #{expected}"}
    end
  end

  defp request_cap("git-upload-pack"), do: @max_upload_pack_request_bytes
  defp request_cap("git-receive-pack"), do: Storage.max_push_bytes()

  defp timeout_ms("git-upload-pack"), do: config(:upload_pack_timeout_ms, @upload_pack_timeout_ms)

  defp timeout_ms("git-receive-pack"),
    do: config(:receive_pack_timeout_ms, @receive_pack_timeout_ms)

  defp config(key, default) do
    :tarakan
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp service_subcommand("git-upload-pack"), do: "upload-pack"
  defp service_subcommand("git-receive-pack"), do: "receive-pack"

  defp git_executable do
    System.find_executable("git") || raise "git executable not found"
  end

  # Only well-formed protocol version advertisements; never pass arbitrary
  # header bytes into the subprocess environment.
  @git_protocol ~r/\Aversion=[0-9]+(?:[:\w.=,-]*)\z/

  defp protocol_env(conn) do
    case get_req_header(conn, "git-protocol") do
      [value | _rest] when byte_size(value) <= 200 ->
        if Regex.match?(@git_protocol, value), do: [{"GIT_PROTOCOL", value}], else: []

      _other ->
        []
    end
  end

  defp port_env(conn) do
    for {key, value} <- Local.env() ++ protocol_env(conn) do
      {String.to_charlist(key), String.to_charlist(value)}
    end
  end

  defp pkt_line(data) do
    size = byte_size(data) + 4
    [String.pad_leading(Integer.to_string(size, 16), 4, "0") |> String.downcase(), data]
  end

  defp close_port(port) do
    if is_port(port) and port in Port.list() do
      Port.close(port)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end
end
