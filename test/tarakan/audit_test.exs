defmodule Tarakan.AuditTest do
  use Tarakan.DataCase, async: true

  alias Ecto.Multi
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Audit
  alias Tarakan.Audit.Event
  alias Tarakan.Repositories.Repository

  test "records actor, opaque credential, subject, repository, and transition details" do
    account = account_fixture()
    repository = repository_fixture()

    scope =
      Scope.for_account(account,
        token_id: 84,
        token_scopes: ["findings:submit"],
        authentication_method: :api_credential
      )

    assert {:ok, event} =
             Audit.record(scope, :review_submitted, repository, %{
               from_state: "draft",
               to_state: "quarantined",
               reason_code: "submission_received",
               request_id: "request-123",
               client_version: "tarakan-client/0.2",
               metadata: %{provenance: "human"}
             })

    assert event.actor_id == account.id
    assert event.token_id == 84
    assert event.action == "review_submitted"
    assert event.subject_type == "Tarakan.Repositories.Repository"
    assert event.subject_id == repository.id
    assert event.repository_id == repository.id
    assert Repo.reload!(event).metadata == %{"provenance" => "human"}
  end

  test "can append events atomically through Ecto.Multi" do
    repository = repository_fixture()

    multi =
      Multi.new()
      |> Audit.append_to_multi(
        :audit_event,
        Scope.for_system(),
        :claim_expired,
        repository,
        %{reason_code: "lease_timeout"}
      )

    assert {:ok, %{audit_event: %Event{} = event}} = Repo.transaction(multi)
    assert event.action == "claim_expired"
    assert is_nil(event.actor_id)
  end

  test "audit history is visible to moderators but not unrelated members" do
    repository = repository_fixture()
    member = account_fixture()
    assert {:ok, _event} = Audit.record(Scope.for_account(member), :review_submitted, repository)

    assert {:error, :unauthorized} =
             Audit.list_repository_events(Scope.for_account(member), repository)

    moderator =
      account_fixture()
      |> Account.authorization_changeset(%{state: "active", platform_role: "moderator"})
      |> Repo.update!()

    assert {:ok, [event]} =
             Audit.list_repository_events(Scope.for_account(moderator), repository)

    assert event.action == "review_submitted"
  end

  test "the database rejects audit event updates" do
    repository = repository_fixture()
    {:ok, event} = Audit.record(Scope.for_system(), :repository_registered, repository)

    assert_raise Postgrex.Error, ~r/audit_events are append-only/, fn ->
      Repo.update_all(from(audit_event in Event, where: audit_event.id == ^event.id),
        set: [action: "rewritten"]
      )
    end
  end

  test "the database rejects audit event deletion" do
    repository = repository_fixture()
    {:ok, event} = Audit.record(Scope.for_system(), :repository_registered, repository)

    assert_raise Postgrex.Error, ~r/audit_events are append-only/, fn ->
      Repo.delete_all(from audit_event in Event, where: audit_event.id == ^event.id)
    end
  end

  defp repository_fixture do
    unique = System.unique_integer([:positive])

    Repo.insert!(%Repository{
      host: "github.com",
      owner: "audit-owner-#{unique}",
      name: "repository-#{unique}",
      canonical_url: "https://github.com/audit-owner-#{unique}/repository-#{unique}"
    })
  end
end
