defmodule Tarakan.GitSSH.Server do
  @moduledoc """
  The SSH endpoint for git access to hosted repositories.

  Wraps an OTP `:ssh.daemon` configured for public-key-only authentication
  against registered account keys (`Tarakan.Accounts.SshKeys`) and an exec
  channel that speaks only `git-upload-pack`/`git-receive-pack`
  (`Tarakan.GitSSH.Channel`). There is no shell, no subsystems, and no
  password authentication.

  The daemon's ed25519 host key is generated on first boot with `ssh-keygen`
  and persisted under the configured directory - losing it makes every known
  client scream about a changed host identity, so the directory must survive
  deploys.
  """

  use GenServer

  require Logger

  @auth_table :tarakan_ssh_auth

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The ETS table where authentication hands the account to the channel."
  def auth_table, do: @auth_table

  @doc "The TCP port the daemon actually bound (useful with `port: 0`)."
  def bound_port(server \\ __MODULE__) do
    GenServer.call(server, :bound_port)
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:tarakan, Tarakan.GitSSH, []), opts)

    if Keyword.get(config, :enabled, false) do
      start_daemon(config)
    else
      :ignore
    end
  end

  defp start_daemon(config) do
    port = Keyword.get(config, :port, 2222)
    host_key_dir = Keyword.get(config, :host_key_dir, "priv/ssh")

    with :ok <- ensure_host_key(host_key_dir),
         :ok <- ensure_auth_table(),
         {:ok, daemon} <- :ssh.daemon(port, daemon_options(config, host_key_dir)) do
      Process.flag(:trap_exit, true)
      {:ok, %{daemon: daemon}}
    else
      {:error, reason} ->
        {:stop, {:git_ssh_daemon_failed, reason}}
    end
  end

  @impl true
  def handle_call(:bound_port, _from, %{daemon: daemon} = state) do
    reply =
      case :ssh.daemon_info(daemon) do
        {:ok, info} -> {:ok, Keyword.fetch!(info, :port)}
        error -> error
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, %{daemon: daemon}) do
    :ssh.stop_daemon(daemon)
    :ok
  end

  defp daemon_options(config, host_key_dir) do
    [
      system_dir: String.to_charlist(host_key_dir),
      key_cb: {Tarakan.GitSSH.KeyStore, []},
      auth_methods: ~c"publickey",
      ssh_cli: {Tarakan.GitSSH.Channel, []},
      subsystems: [],
      id_string: ~c"tarakan",
      parallel_login: true,
      max_sessions: Keyword.get(config, :max_sessions, 50),
      idle_time: Keyword.get(config, :idle_time_ms, :timer.minutes(5))
    ]
  end

  # Public because SSH connection handler processes (not this server) insert
  # authentication results; the channel later takes them out by pid.
  defp ensure_auth_table do
    if :ets.whereis(@auth_table) == :undefined do
      :ets.new(@auth_table, [:named_table, :public, :set])
    end

    :ok
  end

  defp ensure_host_key(host_key_dir) do
    key_path = Path.join(host_key_dir, "ssh_host_ed25519_key")

    if File.exists?(key_path) do
      :ok
    else
      File.mkdir_p!(host_key_dir)

      case System.cmd("ssh-keygen", ["-t", "ed25519", "-f", key_path, "-N", "", "-q"],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          Logger.info("generated SSH host key at #{key_path}")
          :ok

        {output, status} ->
          {:error, {:host_key_generation_failed, status, output}}
      end
    end
  rescue
    error -> {:error, {:host_key_generation_failed, Exception.message(error)}}
  end
end
