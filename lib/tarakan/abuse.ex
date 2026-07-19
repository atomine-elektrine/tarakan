defmodule Tarakan.Abuse do
  @moduledoc """
  Shared anti-abuse helpers: quorum eligibility, client IP hashing, and
  network-collusion detection for independent checks.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts.Account
  alias Tarakan.Repo
  alias Tarakan.Scans.{Confirmation, FindingCheck}

  # New accounts cannot manufacture quorum until they leave probation and age in.
  @min_account_age_hours 24
  # Same client IP cannot farm quorum across sockpuppets on one issue.
  @ip_collusion_days 7

  @doc """
  Whether an account's standing may contribute to verification quorum.

  Probation never counts. Fresh `new`/`contributor` accounts must age in;
  trusted reviewers and platform staff count once active.
  """
  def quorum_eligible?(%Account{} = account) do
    account.state == "active" and (trusted_for_quorum?(account) or account_aged?(account))
  end

  def quorum_eligible?(_), do: false

  def trusted_for_quorum?(%Account{
        trust_tier: "reviewer"
      }),
      do: true

  def trusted_for_quorum?(%Account{platform_role: role}) when role in ["moderator", "admin"],
    do: true

  def trusted_for_quorum?(_), do: false

  @doc "SQL-friendly fragment pieces for quorum account filters."
  def quorum_account_states, do: ["active"]

  def min_account_age_seconds, do: @min_account_age_hours * 3600

  def account_age_cutoff do
    DateTime.add(DateTime.utc_now(), -@min_account_age_hours * 3600, :second)
  end

  defp account_aged?(%Account{inserted_at: %DateTime{} = inserted_at}) do
    DateTime.compare(inserted_at, account_age_cutoff()) != :gt
  end

  defp account_aged?(_), do: false

  @doc """
  Opaque hash of a client IP for collusion signals. Uses the app secret so
  hashes are not reversible offline without the secret.
  """
  def hash_client_ip(nil), do: nil
  def hash_client_ip(""), do: nil

  def hash_client_ip(ip) when is_binary(ip) do
    secret = Application.get_env(:tarakan, TarakanWeb.Endpoint)[:secret_key_base] || "tarakan"
    :crypto.mac(:hmac, :sha256, secret, "client-ip:" <> String.trim(ip))
  end

  def hash_client_ip(_), do: nil

  @doc """
  True when another account already checked this canonical finding from the
  same client IP recently. Used to withhold quorum credit, not to hide the check.
  """
  def colluding_ip_check?(canonical_id, account_id, client_ip_hash)
      when is_integer(canonical_id) and is_integer(account_id) and is_binary(client_ip_hash) do
    since = DateTime.add(DateTime.utc_now(), -@ip_collusion_days, :day)

    Repo.exists?(
      from check in FindingCheck,
        where:
          check.canonical_finding_id == ^canonical_id and
            check.account_id != ^account_id and
            check.client_ip_hash == ^client_ip_hash and
            check.inserted_at >= ^since
    )
  end

  def colluding_ip_check?(_canonical_id, _account_id, _hash), do: false

  @doc "Same-network collusion for whole-report confirmations."
  def colluding_ip_confirmation?(scan_id, account_id, client_ip_hash)
      when is_integer(scan_id) and is_integer(account_id) and is_binary(client_ip_hash) do
    since = DateTime.add(DateTime.utc_now(), -@ip_collusion_days, :day)

    Repo.exists?(
      from confirmation in Confirmation,
        where:
          confirmation.scan_id == ^scan_id and
            confirmation.account_id != ^account_id and
            confirmation.client_ip_hash == ^client_ip_hash and
            confirmation.inserted_at >= ^since
    )
  end

  def colluding_ip_confirmation?(_scan_id, _account_id, _hash), do: false
end
