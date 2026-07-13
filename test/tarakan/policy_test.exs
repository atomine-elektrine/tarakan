defmodule Tarakan.PolicyTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Policy
  alias Tarakan.Repositories.Repository

  describe "deny-by-default authorization" do
    test "only explicit public actions allow anonymous callers" do
      assert :ok = Policy.authorize(nil, :view_public_repository)
      assert {:error, :unauthorized} = Policy.authorize(nil, :submit_review)
      assert {:error, :unauthorized} = Policy.authorize(nil, :invented_action)
    end

    test "suspended and banned accounts cannot mutate even when they are administrators" do
      repository = repository_fixture()

      for state <- ["suspended", "banned"] do
        account =
          account_fixture()
          |> set_authorization(%{state: state, platform_role: "admin", trust_tier: "reviewer"})

        scope = Scope.for_account(account)

        assert {:error, :unauthorized} = Policy.authorize(scope, :submit_review, repository)
        assert {:error, :unauthorized} = Policy.authorize(scope, :moderate, repository)
        assert {:error, :unauthorized} = Policy.authorize(scope, :administer)
      end
    end

    test "restricted accounts may report and appeal but cannot change workflow state" do
      repository = repository_fixture()

      account = account_fixture() |> set_authorization(%{state: "restricted"})
      scope = Scope.for_account(account)

      assert :ok = Policy.authorize(scope, :report_content, repository)
      assert :ok = Policy.authorize(scope, :appeal_moderation, repository)
      assert {:error, :unauthorized} = Policy.authorize(scope, :submit_review, repository)
    end
  end

  describe "credential boundaries" do
    test "checks both explicit grants and repository binding" do
      account = account_fixture() |> set_authorization(%{state: "active"})
      repository = repository_fixture()
      other_repository = repository_fixture()

      scope =
        Scope.for_account(account,
          token_id: 123,
          token_scopes: ["tasks:claim"],
          token_repository_id: repository.id,
          authentication_method: :api_credential
        )

      assert :ok = Policy.authorize(scope, :claim_task, repository)

      assert {:error, :unauthorized} =
               Policy.authorize(scope, :claim_task, other_repository)

      assert {:error, :unauthorized} = Policy.authorize(scope, :claim_task)
      assert {:error, :unauthorized} = Policy.authorize(scope, :submit_review, repository)
    end

    test "browser scopes allow session actions while malformed API scopes fail closed" do
      account = account_fixture()
      repository = repository_fixture()

      assert :ok = Policy.authorize(Scope.for_account(account), :submit_review, repository)

      malformed_api_scope =
        Scope.for_account(account,
          token_id: 123,
          token_scopes: nil,
          authentication_method: :api_credential
        )

      assert {:error, :unauthorized} =
               Policy.authorize(malformed_api_scope, :submit_review, repository)
    end

    test "reporting requires reports:write on explicitly scoped credentials" do
      account = account_fixture() |> set_authorization(%{state: "restricted"})
      repository = repository_fixture()

      denied = Scope.for_account(account, token_scopes: ["tasks:read"])
      allowed = Scope.for_account(account, token_scopes: ["reports:write"])

      assert {:error, :unauthorized} = Policy.authorize(denied, :report_content, repository)
      assert :ok = Policy.authorize(allowed, :report_content, repository)
    end
  end

  describe "roles and repository relationships" do
    test "only verified reviewer relationships participate in review authorization" do
      account = account_fixture() |> set_authorization(%{state: "active"})
      repository = repository_fixture()

      pending =
        Scope.for_account(account,
          repository_memberships: [
            %{repository_id: repository.id, role: "reviewer", status: "pending"}
          ]
        )

      verified =
        Scope.put_repository_memberships(pending, [
          %{repository_id: repository.id, role: "reviewer", status: "verified"}
        ])

      assert {:error, :unauthorized} = Policy.authorize(pending, :verify_review, repository)
      assert :ok = Policy.authorize(verified, :verify_review, repository)
      assert {:error, :unauthorized} = Policy.authorize(verified, :moderate_review, repository)
    end

    test "a platform reviewer-tier account may verify across repositories" do
      repository = repository_fixture()

      reviewer =
        account_fixture()
        |> set_authorization(%{state: "active", platform_role: "member", trust_tier: "reviewer"})

      newcomer =
        account_fixture()
        |> set_authorization(%{state: "active", platform_role: "member", trust_tier: "new"})

      reviewer_scope = Scope.for_account(reviewer)
      newcomer_scope = Scope.for_account(newcomer)

      # Reviewer-tier qualifies for verification and restricted reads on any repo,
      # without a per-repo membership.
      assert :ok = Policy.authorize(reviewer_scope, :verify_review, repository)
      assert :ok = Policy.authorize(reviewer_scope, :view_restricted_review, repository)

      # A newcomer-tier account does not.
      assert {:error, :unauthorized} =
               Policy.authorize(newcomer_scope, :verify_review, repository)

      assert {:error, :unauthorized} =
               Policy.authorize(newcomer_scope, :view_restricted_review, repository)
    end

    test "verified stewards may moderate reviews and manage their repository only" do
      account = account_fixture() |> set_authorization(%{state: "active"})
      repository = repository_fixture()
      other_repository = repository_fixture()

      scope =
        Scope.for_account(account,
          repository_memberships: [
            %{repository_id: repository.id, role: "steward", status: "verified"}
          ]
        )

      assert :ok = Policy.authorize(scope, :moderate_review, repository)
      assert :ok = Policy.authorize(scope, :manage_repository, repository)
      assert :ok = Policy.authorize(scope, :disclose_task, repository)

      assert {:error, :unauthorized} =
               Policy.authorize(scope, :manage_repository, other_repository)

      assert {:error, :unauthorized} =
               Policy.authorize(scope, :disclose_task, other_repository)
    end

    test "trust tier alone is not a global review grant" do
      reviewer =
        account_fixture()
        |> set_authorization(%{state: "active", trust_tier: "reviewer"})

      repository = repository_fixture()
      task = %{id: 91, repository_id: repository.id, created_by_id: -1}
      unscoped = Scope.for_account(reviewer)

      assert {:error, :unauthorized} =
               Policy.authorize(unscoped, :view_restricted_task, task)

      assert {:error, :unauthorized} =
               Policy.authorize(unscoped, :review_contribution, task)

      repository_scope =
        Scope.put_repository_memberships(unscoped, [
          %{
            repository_id: repository.id,
            account_id: reviewer.id,
            role: "reviewer",
            status: "verified"
          }
        ])

      assert :ok = Policy.authorize(repository_scope, :view_restricted_task, task)
      assert :ok = Policy.authorize(repository_scope, :review_contribution, task)
    end

    test "paused repositories reject community mutations unless a moderator intervenes" do
      repository = repository_fixture("paused")
      member = account_fixture() |> set_authorization(%{state: "active"})

      moderator =
        account_fixture()
        |> set_authorization(%{state: "active", platform_role: "moderator"})

      assert {:error, :unauthorized} =
               Policy.authorize(Scope.for_account(member), :submit_review, repository)

      for action <- [
            :verify_review,
            :moderate_review,
            :propose_task,
            :publish_task,
            :disclose_task,
            :claim_task,
            :submit_contribution,
            :review_contribution
          ] do
        assert {:error, :unauthorized} =
                 Policy.authorize(Scope.for_account(member), action, repository)
      end

      assert :ok =
               Policy.authorize(Scope.for_account(moderator), :submit_review, repository)
    end
  end

  describe "git hosting actions" do
    test "anyone may clone a listed repository, including anonymously" do
      listed = repository_fixture() |> listing("listed")

      assert :ok = Policy.authorize(nil, :clone_repository, listed)

      account = account_fixture() |> set_authorization(%{state: "active"})
      assert :ok = Policy.authorize(Scope.for_account(account), :clone_repository, listed)
    end

    test "pending repositories are cloneable only with a verified relationship" do
      pending = repository_fixture() |> listing("pending")

      assert {:error, :unauthorized} = Policy.authorize(nil, :clone_repository, pending)

      outsider = account_fixture() |> set_authorization(%{state: "active"})

      assert {:error, :unauthorized} =
               Policy.authorize(Scope.for_account(outsider), :clone_repository, pending)

      reviewer_scope =
        Scope.for_account(outsider,
          repository_memberships: [
            %{repository_id: pending.id, role: "reviewer", status: "verified"}
          ]
        )

      assert :ok = Policy.authorize(reviewer_scope, :clone_repository, pending)
    end

    test "only verified stewards and moderators may push" do
      repository = repository_fixture()
      account = account_fixture() |> set_authorization(%{state: "active"})

      assert {:error, :unauthorized} = Policy.authorize(nil, :push_repository, repository)

      assert {:error, :unauthorized} =
               Policy.authorize(Scope.for_account(account), :push_repository, repository)

      reviewer_scope =
        Scope.for_account(account,
          repository_memberships: [
            %{repository_id: repository.id, role: "reviewer", status: "verified"}
          ]
        )

      assert {:error, :unauthorized} =
               Policy.authorize(reviewer_scope, :push_repository, repository)

      steward_scope =
        Scope.for_account(account,
          repository_memberships: [
            %{repository_id: repository.id, role: "steward", status: "verified"}
          ]
        )

      assert :ok = Policy.authorize(steward_scope, :push_repository, repository)

      moderator =
        account_fixture() |> set_authorization(%{state: "active", platform_role: "moderator"})

      assert :ok = Policy.authorize(Scope.for_account(moderator), :push_repository, repository)
    end

    test "credential scopes gate git actions for token-authenticated callers" do
      repository = repository_fixture()
      account = account_fixture() |> set_authorization(%{state: "active"})

      steward_membership = [
        %{repository_id: repository.id, role: "steward", status: "verified"}
      ]

      read_only =
        Scope.for_account(account,
          repository_memberships: steward_membership,
          token_id: 1,
          token_scopes: ["repo:read"],
          authentication_method: :api_credential
        )

      write =
        Scope.for_account(account,
          repository_memberships: steward_membership,
          token_id: 1,
          token_scopes: ["repo:write"],
          authentication_method: :api_credential
        )

      unrelated =
        Scope.for_account(account,
          repository_memberships: steward_membership,
          token_id: 1,
          token_scopes: ["tasks:read"],
          authentication_method: :api_credential
        )

      pending = repository_fixture() |> listing("pending")

      assert {:error, :unauthorized} = Policy.authorize(read_only, :push_repository, repository)
      assert :ok = Policy.authorize(write, :push_repository, repository)
      assert {:error, :unauthorized} = Policy.authorize(unrelated, :push_repository, repository)
      assert {:error, :unauthorized} = Policy.authorize(unrelated, :clone_repository, pending)
    end

    test "a paused repository rejects pushes but stays cloneable when listed" do
      repository = repository_fixture("paused") |> listing("listed")
      account = account_fixture() |> set_authorization(%{state: "active"})

      steward_scope =
        Scope.for_account(account,
          repository_memberships: [
            %{repository_id: repository.id, role: "steward", status: "verified"}
          ]
        )

      assert {:error, :unauthorized} =
               Policy.authorize(steward_scope, :push_repository, repository)

      assert :ok = Policy.authorize(nil, :clone_repository, repository)
    end
  end

  defp listing(repository, status) do
    repository
    |> Ecto.Changeset.change(listing_status: status)
    |> Repo.update!()
  end

  defp set_authorization(account, attrs) do
    account
    |> Account.authorization_changeset(attrs)
    |> Repo.update!()
  end

  defp repository_fixture(participation_mode \\ "community") do
    unique = System.unique_integer([:positive])

    Repo.insert!(%Repository{
      host: "github.com",
      owner: "policy-owner-#{unique}",
      name: "repository-#{unique}",
      canonical_url: "https://github.com/policy-owner-#{unique}/repository-#{unique}",
      participation_mode: participation_mode
    })
  end
end
