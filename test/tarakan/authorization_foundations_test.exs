defmodule Tarakan.AuthorizationFoundationsTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Accounts
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository

  test "new accounts receive conservative authorization defaults" do
    account = account_fixture()
    scope = Scope.for_account(account)

    assert account.state == "probation"
    assert account.platform_role == "member"
    assert account.trust_tier == "new"
    assert scope.account_id == account.id
    assert scope.account_state == "probation"
    assert scope.repository_memberships == %{}
  end

  test "account authorization fields reject unknown values" do
    changeset =
      Account.authorization_changeset(account_fixture(), %{
        state: "shadow_banned",
        platform_role: "owner",
        trust_tier: "expert"
      })

    refute changeset.valid?
    assert "is invalid" in errors_on(changeset).state
    assert "is invalid" in errors_on(changeset).platform_role
    assert "is invalid" in errors_on(changeset).trust_tier
  end

  test "only an administrator can change account authorization" do
    target = account_fixture()
    ordinary = account_fixture()

    assert {:error, :unauthorized} =
             Accounts.update_authorization(Scope.for_account(ordinary), target, %{state: "active"})

    admin =
      account_fixture()
      |> Account.authorization_changeset(%{state: "active", platform_role: "admin"})
      |> Repo.update!()

    assert {:ok, updated} =
             Accounts.update_authorization(Scope.for_account(admin), target, %{
               state: "active",
               trust_tier: "contributor"
             })

    assert updated.state == "active"
    assert updated.trust_tier == "contributor"
  end

  test "account authorization rechecks a stale administrator scope under lock" do
    target = account_fixture()

    admin =
      account_fixture()
      |> Account.authorization_changeset(%{state: "active", platform_role: "admin"})
      |> Repo.update!()

    stale_scope = Scope.for_account(admin)

    admin
    |> Account.authorization_changeset(%{platform_role: "member"})
    |> Repo.update!()

    assert {:error, :unauthorized} =
             Accounts.update_authorization(stale_scope, target, %{state: "suspended"})

    assert Accounts.get_account!(target.id).state == "probation"
  end

  test "the last effective administrator cannot be demoted or restricted" do
    admin =
      account_fixture()
      |> Account.authorization_changeset(%{
        state: "active",
        platform_role: "admin",
        trust_tier: "reviewer"
      })
      |> Repo.update!()

    scope = Scope.for_account(admin)

    assert {:error, :last_admin} =
             Accounts.update_authorization(scope, admin, %{platform_role: "member"})

    assert {:error, :last_admin} =
             Accounts.update_authorization(scope, admin, %{state: "suspended"})

    second_admin =
      account_fixture()
      |> Account.authorization_changeset(%{state: "active", platform_role: "admin"})
      |> Repo.update!()

    assert {:ok, demoted} =
             Accounts.update_authorization(Scope.for_account(second_admin), admin, %{
               platform_role: "member"
             })

    assert demoted.platform_role == "member"
  end

  test "only administrators can list and inspect platform accounts" do
    target = account_fixture(%{handle: "searchable-target"})
    member = account_fixture()

    assert {:error, :unauthorized} =
             Accounts.list_accounts_for_admin(Scope.for_account(member), "searchable")

    admin =
      account_fixture()
      |> Account.authorization_changeset(%{state: "active", platform_role: "admin"})
      |> Repo.update!()

    assert {:ok, [listed]} =
             Accounts.list_accounts_for_admin(Scope.for_account(admin), "searchable")

    assert listed.id == target.id
    assert {:ok, inspected} = Accounts.get_account_for_admin(Scope.for_account(admin), target.id)
    assert inspected.id == target.id
  end

  test "memberships grant no authority until independently verified" do
    repository = repository_fixture()
    candidate = account_fixture()
    ordinary = account_fixture()

    assert {:ok, membership} =
             Repositories.propose_repository_membership(
               Scope.for_account(candidate),
               repository,
               candidate,
               %{role: "steward"}
             )

    assert membership.status == "pending"
    assert is_nil(membership.verified_at)

    assert {:error, :unauthorized} =
             Repositories.set_repository_membership_status(
               Scope.for_account(ordinary),
               membership,
               :verified
             )

    moderator =
      account_fixture()
      |> Account.authorization_changeset(%{state: "active", platform_role: "moderator"})
      |> Repo.update!()

    assert {:ok, verified} =
             Repositories.set_repository_membership_status(
               Scope.for_account(moderator),
               membership,
               :verified
             )

    assert verified.status == "verified"
    assert verified.verified_by_account_id == moderator.id
    assert %DateTime{} = verified.verified_at

    enriched_scope = Accounts.scope_for_account(candidate)
    assert Scope.repository_role?(enriched_scope, repository, "steward")

    assert {:ok, paused} =
             Repositories.update_participation_mode(enriched_scope, repository, %{
               participation_mode: "paused"
             })

    assert paused.participation_mode == "paused"

    assert {:error, :unauthorized} =
             Repositories.update_participation_mode(enriched_scope, paused, %{
               participation_mode: "curated"
             })

    assert {:ok, curated} =
             Repositories.update_participation_mode(Scope.for_account(moderator), paused, %{
               participation_mode: "curated"
             })

    assert curated.participation_mode == "curated"
  end

  test "revoked repository authority cannot be reused from a stale scope" do
    repository = repository_fixture()
    steward = account_fixture()

    moderator =
      account_fixture()
      |> Account.authorization_changeset(%{state: "active", platform_role: "moderator"})
      |> Repo.update!()

    assert {:ok, membership} =
             Repositories.propose_repository_membership(
               Scope.for_account(steward),
               repository,
               steward,
               %{role: "steward"}
             )

    assert {:ok, verified} =
             Repositories.set_repository_membership_status(
               Scope.for_account(moderator),
               membership,
               :verified
             )

    stale_scope = Accounts.scope_for_account(steward)

    assert {:ok, _revoked} =
             Repositories.set_repository_membership_status(
               Scope.for_account(moderator),
               verified,
               :revoked
             )

    assert {:error, :unauthorized} =
             Repositories.update_participation_mode(stale_scope, repository, %{
               participation_mode: "paused"
             })

    assert Repo.get!(Repository, repository.id).participation_mode == "unclaimed"
  end

  test "a moderator cannot verify their own proposed repository role" do
    repository = repository_fixture()

    moderator =
      account_fixture()
      |> Account.authorization_changeset(%{state: "active", platform_role: "moderator"})
      |> Repo.update!()

    assert {:ok, membership} =
             Repositories.propose_repository_membership(
               Scope.for_account(moderator),
               repository,
               moderator,
               %{role: "steward"}
             )

    assert {:error, :conflict_of_interest} =
             Repositories.set_repository_membership_status(
               Scope.for_account(moderator),
               membership,
               :verified
             )
  end

  test "an account cannot propose a relationship for another account" do
    proposer = account_fixture()

    assert {:error, :unauthorized} =
             Repositories.propose_repository_membership(
               Scope.for_account(proposer),
               repository_fixture(),
               account_fixture(),
               %{role: "reviewer"}
             )
  end

  defp repository_fixture do
    unique = System.unique_integer([:positive])

    Repo.insert!(%Repository{
      host: "github.com",
      owner: "membership-owner-#{unique}",
      name: "repository-#{unique}",
      canonical_url: "https://github.com/membership-owner-#{unique}/repository-#{unique}"
    })
  end
end
