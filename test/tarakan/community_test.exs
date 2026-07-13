defmodule Tarakan.CommunityTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Accounts.Scope
  alias Tarakan.Audit.Event
  alias Tarakan.Community

  test "posts trimmed public shouts and keeps newest first" do
    account = account_fixture()
    scope = Scope.for_account(account)

    assert {:ok, first} = Community.create_shout(scope, %{"body" => "  Reviewing auth today.  "})

    assert {:ok, second} =
             Community.create_shout(scope, %{"body" => "Could use another set of eyes."})

    assert first.body == "Reviewing auth today."
    assert Enum.map(Community.list_shouts(nil), & &1.id) == [second.id, first.id]

    assert Tarakan.Repo.get_by(Event,
             action: "registry_shout_posted",
             subject_id: first.id,
             actor_id: account.id
           )
  end

  test "rejects anonymous and oversized shouts" do
    assert {:error, :unauthorized} = Community.create_shout(nil, %{"body" => "hello"})

    assert {:error, changeset} =
             Community.create_shout(Scope.for_account(account_fixture()), %{
               "body" => String.duplicate("x", 281)
             })

    assert "should be at most 280 character(s)" in errors_on(changeset).body
  end

  test "moderation leaves a public placeholder and an audit event" do
    author = account_fixture()

    {:ok, shout} =
      Community.create_shout(Scope.for_account(author), %{"body" => "This will be removed."})

    moderator = moderator_account_fixture()

    assert {:ok, removed} =
             Community.remove_shout(Scope.for_account(moderator), shout, %{
               "removed_reason" => "off_topic"
             })

    assert removed.removed_at
    assert [public] = Community.list_shouts(nil)
    assert public.body == nil

    assert Tarakan.Repo.get_by(Event,
             action: "registry_shout_removed",
             subject_id: shout.id,
             actor_id: moderator.id
           )
  end

  test "ordinary accounts cannot remove another person's shout" do
    {:ok, shout} =
      Community.create_shout(Scope.for_account(account_fixture()), %{"body" => "Public note"})

    assert {:error, :unauthorized} =
             Community.remove_shout(
               Scope.for_account(account_fixture()),
               shout,
               %{"removed_reason" => "not_mine"}
             )
  end
end
