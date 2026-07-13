defmodule Tarakan.GitSSH.KeyStore do
  @moduledoc """
  Public-key authentication against registered account keys.

  `is_auth_key/3` runs inside the SSH connection handler process. On success
  it records `{self(), account_id, ssh_key_id}` in a public ETS table; the
  channel process later resolves the same pid (its connection manager) back
  to the account. If that handoff ever fails, the channel falls back to the
  username-as-handle lookup and otherwise fails closed - it never guesses.

  The SSH username must be either the conventional `git` or the account's
  own handle; a key can never authenticate as somebody else's handle.
  """

  @behaviour :ssh_server_key_api

  alias Tarakan.Accounts.SshKeys
  alias Tarakan.GitSSH.Server

  require Logger

  @impl true
  def host_key(algorithm, daemon_options) do
    :ssh_file.host_key(algorithm, daemon_options)
  end

  @impl true
  def is_auth_key(public_key, user, _daemon_options) do
    with {:ok, account, ssh_key} <- SshKeys.find_account_by_key(public_key),
         true <- Tarakan.Accounts.Account.access_allowed?(account),
         :ok <- validate_user(user, account) do
      :ets.insert(Server.auth_table(), {self(), account.id, ssh_key.id})
      true
    else
      _denied -> false
    end
  rescue
    error ->
      Logger.warning("SSH key authentication crashed: #{Exception.message(error)}")
      false
  end

  defp validate_user(user, account) do
    case to_string(user) do
      "git" -> :ok
      handle when handle == account.handle -> :ok
      _other -> :error
    end
  end
end
