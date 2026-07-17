defmodule Tarakan.GitSSH.Channel do
  @moduledoc """
  The SSH exec channel: accepts exactly `git-upload-pack '<owner>/<name>.git'`
  and `git-receive-pack '<owner>/<name>.git'`, nothing else.

  Unlike the smart-HTTP RPCs, SSH transport is interactive (a fetch
  negotiates over multiple rounds), so git runs *without* `--stateless-rpc`
  and the channel pumps bytes both ways between the SSH connection and the
  subprocess port. The pack protocol is self-delimiting in both directions,
  which is what makes the port's missing stdin-EOF harmless; a hard deadline
  guards the pathological remainder.

  Shell and pty requests are refused. Authorization mirrors HTTP:
  `:clone_repository` for upload-pack, `:push_repository` for receive-pack,
  through `Tarakan.Policy` with an `:ssh_key` scope. There is no anonymous
  SSH - public-key auth already identified the account.
  """

  @behaviour :ssh_server_channel

  alias Tarakan.Accounts
  alias Tarakan.Accounts.SshKey
  alias Tarakan.Git.Concurrency
  alias Tarakan.Git.Local
  alias Tarakan.HostedRepositories
  alias Tarakan.HostedRepositories.Storage
  alias Tarakan.Policy
  alias Tarakan.GitSSH.Server
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository

  require Logger

  @command_pattern ~r{\A\s*(?:git[ -])(upload-pack|receive-pack)\s+'?/?([a-z0-9][a-z0-9_-]*)/([a-z0-9._-]+?)(?:\.git)?/?'?\s*\z}

  @upload_pack_timeout_ms :timer.minutes(10)
  @receive_pack_timeout_ms :timer.minutes(10)

  @impl true
  def init(_args) do
    {:ok,
     %{
       cm: nil,
       channel_id: nil,
       account: nil,
       ssh_key_id: nil,
       scope: nil,
       repository: nil,
       service: nil,
       port: nil,
       concurrency_held?: false,
       exit_sent: false
     }}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, cm}, state) do
    state = %{state | cm: cm, channel_id: channel_id}
    {:ok, resolve_account(state)}
  end

  def handle_msg({port, {:data, data}}, %{port: port} = state) do
    case :ssh_connection.send(state.cm, state.channel_id, data, :timer.seconds(30)) do
      :ok -> {:ok, state}
      {:error, _reason} -> stop(state)
    end
  end

  def handle_msg({port, {:exit_status, status}}, %{port: port} = state) do
    if status == 0 and state.service == "receive-pack" do
      after_receive_pack(state)
    end

    finish(state, status)
  end

  def handle_msg(:git_deadline, state) do
    Logger.warning("git SSH channel deadline reached; closing")
    stop(state)
  end

  def handle_msg(_message, state), do: {:ok, state}

  @impl true
  def handle_ssh_msg({:ssh_cm, cm, {:exec, channel_id, want_reply, command}}, %{cm: cm} = state) do
    case authorize_exec(state, to_string(command)) do
      {:ok, service, repository, scope} ->
        case Concurrency.checkout() do
          :ok ->
            :ssh_connection.reply_request(cm, want_reply, :success, channel_id)

            :telemetry.execute([:tarakan, :git, :ssh, :request], %{count: 1}, %{
              service: service,
              repository_id: repository.id
            })

            port = open_git_port(service, repository)
            Process.send_after(self(), :git_deadline, timeout_ms(service))

            {:ok,
             %{
               state
               | service: service,
                 repository: repository,
                 scope: scope,
                 port: port,
                 concurrency_held?: true
             }}

          {:error, :busy} ->
            :ssh_connection.reply_request(cm, want_reply, :success, channel_id)
            _ = :ssh_connection.send(cm, channel_id, 1, "git service busy; try again shortly\n")
            finish(state, 1)
        end

      {:error, message} ->
        :ssh_connection.reply_request(cm, want_reply, :success, channel_id)
        _ = :ssh_connection.send(cm, channel_id, 1, message <> "\n")
        finish(state, 1)
    end
  end

  def handle_ssh_msg({:ssh_cm, cm, {:data, channel_id, 0, data}}, %{cm: cm} = state) do
    if state.port do
      Port.command(state.port, data)
      {:ok, state}
    else
      {:stop, channel_id, state}
    end
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:data, _channel_id, _type, _data}}, state), do: {:ok, state}

  # The protocol is self-delimiting; the subprocess exits on its own after
  # the final pkt, so client EOF needs no forwarding.
  def handle_ssh_msg({:ssh_cm, _cm, {:eof, _channel_id}}, state), do: {:ok, state}

  def handle_ssh_msg({:ssh_cm, cm, {:shell, channel_id, want_reply}}, %{cm: cm} = state) do
    :ssh_connection.reply_request(cm, want_reply, :failure, channel_id)
    {:stop, channel_id, state}
  end

  def handle_ssh_msg({:ssh_cm, cm, {:pty, channel_id, want_reply, _options}}, %{cm: cm} = state) do
    :ssh_connection.reply_request(cm, want_reply, :failure, channel_id)
    {:ok, state}
  end

  def handle_ssh_msg(
        {:ssh_cm, cm, {:env, channel_id, want_reply, _var, _value}},
        %{cm: cm} = state
      ) do
    :ssh_connection.reply_request(cm, want_reply, :failure, channel_id)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:signal, _channel_id, _signal}}, state), do: {:ok, state}

  def handle_ssh_msg({:ssh_cm, _cm, {:exit_signal, channel_id, _signal, _error, _lang}}, state),
    do: {:stop, channel_id, state}

  def handle_ssh_msg({:ssh_cm, _cm, {:exit_status, channel_id, _status}}, state),
    do: {:stop, channel_id, state}

  def handle_ssh_msg(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    if state.port && state.port in Port.list() do
      Port.close(state.port)
    end

    release_concurrency(state)
    :ok
  end

  ## Authentication handoff

  # `is_auth_key/3` ran in the connection handler process - the same pid the
  # channel knows as `cm`. If the ETS entry is missing (an OTP internals
  # change would surface exactly here), fall back to the username when it is
  # an account handle; otherwise the channel stays unauthenticated and every
  # exec is refused.
  defp resolve_account(state) do
    case :ets.take(Server.auth_table(), state.cm) do
      [{_pid, account_id, ssh_key_id}] ->
        case Repo.get(Accounts.Account, account_id) do
          %Accounts.Account{} = account ->
            %{state | account: account, ssh_key_id: ssh_key_id}

          nil ->
            state
        end

      [] ->
        resolve_account_by_username(state)
    end
  rescue
    _error -> state
  end

  defp resolve_account_by_username(state) do
    with [user: user] <- :ssh.connection_info(state.cm, [:user]),
         handle when handle != "git" <- to_string(user),
         %Accounts.Account{} = account <- Accounts.get_account_by_handle(handle) do
      Logger.warning("SSH auth ETS handoff missed; resolved account by handle")
      %{state | account: account}
    else
      _other -> state
    end
  rescue
    _error -> state
  end

  ## Exec authorization

  defp authorize_exec(%{account: nil}, _command), do: {:error, "access denied"}

  defp authorize_exec(%{account: account}, command) do
    with {:ok, service, owner, name} <- parse_command(command),
         %Repository{} = repository <- HostedRepositories.resolve(owner, name),
         scope = Accounts.scope_for_account(account, authentication_method: :ssh_key),
         :ok <- Policy.authorize(scope, action_for(service), repository) do
      {:ok, service, repository, scope}
    else
      {:error, :unsupported_command} ->
        {:error, "only git-upload-pack and git-receive-pack are supported"}

      # Missing repository and denied authorization are indistinguishable.
      _denied ->
        {:error, "repository not found"}
    end
  end

  defp parse_command(command) do
    case Regex.run(@command_pattern, command, capture: :all_but_first) do
      [service, owner, name] -> {:ok, service, owner, name}
      nil -> {:error, :unsupported_command}
    end
  end

  defp action_for("upload-pack"), do: :clone_repository
  defp action_for("receive-pack"), do: :push_repository

  ## Subprocess

  defp open_git_port(service, repository) do
    Port.open(
      {:spawn_executable, git_executable()},
      [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: [service, Storage.dir(repository)],
        env:
          for(
            {key, value} <- Local.env(),
            do: {String.to_charlist(key), String.to_charlist(value)}
          )
      ]
    )
  end

  defp git_executable do
    System.find_executable("git") || raise "git executable not found"
  end

  defp timeout_ms("upload-pack"), do: @upload_pack_timeout_ms
  defp timeout_ms("receive-pack"), do: @receive_pack_timeout_ms

  defp after_receive_pack(state) do
    Tarakan.HostedRepositories.PostReceive.run(state.repository, state.scope)

    if state.ssh_key_id do
      Tarakan.Accounts.SshKeys.touch_last_used(%SshKey{id: state.ssh_key_id})
    end

    :ok
  rescue
    error ->
      Logger.warning("SSH post-receive failed: #{Exception.message(error)}")
      :ok
  end

  ## Channel shutdown

  defp finish(state, exit_status) do
    state = release_concurrency(state)
    _ = :ssh_connection.send_eof(state.cm, state.channel_id)
    _ = :ssh_connection.exit_status(state.cm, state.channel_id, exit_status)
    {:stop, state.channel_id, %{state | exit_sent: true, port: nil}}
  end

  defp stop(state) do
    {:stop, state.channel_id, release_concurrency(state)}
  end

  defp release_concurrency(%{concurrency_held?: true} = state) do
    Concurrency.checkin()
    %{state | concurrency_held?: false}
  end

  defp release_concurrency(state), do: state
end
