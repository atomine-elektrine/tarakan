defmodule Tarakan.ScansFixtures do
  @moduledoc """
  Test helpers for creating entities via the `Tarakan.Scans` context.
  """

  import Tarakan.AccountsFixtures

  alias Tarakan.Repositories
  alias Tarakan.Scans
  alias Tarakan.Accounts.Account

  @doc """
  Registers the one repository the GitHub stub can verify.
  """
  def github_repository_fixture(account \\ nil) do
    account = account || github_account_fixture()
    {:ok, repository} = Repositories.register_github_repository("openai/codex", account)
    repository
  end

  @doc "Registers the GitHub fixture and makes it visible for public-record tests."
  def listed_github_repository_fixture(account \\ nil) do
    account
    |> github_repository_fixture()
    |> listed_repository_fixture()
  end

  def listed_repository_fixture(repository) do
    repository
    |> Tarakan.Repositories.Repository.listing_changeset(%{listing_status: "listed"})
    |> Tarakan.Repo.update!()
  end

  def valid_scan_attributes(overrides \\ %{}) do
    Enum.into(overrides, %{
      "commit_sha" => random_commit_sha(),
      "model" => "claude-sonnet-5",
      "prompt_version" => "tarakan-baseline/v1",
      "run_id" => "fixture-#{System.unique_integer([:positive, :monotonic])}",
      "findings_json" => nil
    })
  end

  def scan_fixture(repository, account, overrides \\ %{}) do
    {:ok, scan} = Scans.submit_scan(repository, account, valid_scan_attributes(overrides))
    scan
  end

  def confirmation_fixture(scan, account, verdict \\ "confirmed") do
    account = reviewer_account(account)

    {:ok, scan} =
      Scans.record_confirmation(scan, account, %{
        "verdict" => verdict,
        "notes" =>
          "Independently traced and reproduced the reported behavior in a local checkout."
      })

    scan
  end

  def reviewer_account_fixture do
    account_fixture() |> reviewer_account()
  end

  def moderator_account_fixture do
    account_fixture() |> moderator_account()
  end

  def moderator_account(account) do
    account
    |> Account.authorization_changeset(%{
      state: "active",
      platform_role: "moderator",
      trust_tier: "reviewer"
    })
    |> Tarakan.Repo.update!()
  end

  def reviewer_account(%Account{platform_role: "moderator", trust_tier: "reviewer"} = account),
    do: account

  def reviewer_account(account) do
    account
    |> Account.authorization_changeset(%{
      state: "active",
      platform_role: "moderator",
      trust_tier: "reviewer"
    })
    |> Tarakan.Repo.update!()
  end

  def findings_json_fixture(count \\ 1) do
    findings =
      for index <- 1..count do
        %{
          "file" => "lib/example/module_#{index}.ex",
          "line_start" => index * 10,
          "line_end" => index * 10 + 5,
          "severity" => "high",
          "title" => "Unsanitized input reaches interpolated query (#{index})",
          "description" => "String-built SQL executed with request parameters."
        }
      end

    Jason.encode!(%{"tarakan_scan_format" => 1, "findings" => findings})
  end

  def random_commit_sha do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower) |> Kernel.<>("00000000")
  end
end
