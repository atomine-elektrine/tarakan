defmodule Tarakan.WorkFixtures do
  @moduledoc """
  Test helpers for the public review work queue.
  """

  alias Tarakan.Work

  def proposed_review_task_fixture(repository, creator, overrides \\ %{}) do
    {:ok, task} =
      Work.create_task(repository, creator, valid_review_task_attributes(overrides))

    task
  end

  def valid_review_task_attributes(overrides \\ %{}) do
    Enum.into(overrides, %{
      "commit_sha" => Tarakan.ScansFixtures.random_commit_sha(),
      "kind" => "threat_model",
      "capability" => "human",
      "title" => "Map the authorization boundary",
      "description" => "Trace organization membership checks and document trust assumptions."
    })
  end

  def review_task_fixture(repository, creator, overrides \\ %{}) do
    task = proposed_review_task_fixture(repository, creator, overrides)
    publisher = Tarakan.AccountsFixtures.account_fixture()

    publisher =
      publisher
      |> Tarakan.Accounts.Account.authorization_changeset(%{
        state: "active",
        platform_role: "moderator",
        trust_tier: "reviewer"
      })
      |> Tarakan.Repo.update!()

    {:ok, task} =
      Work.publish_task(task, publisher, %{
        "reason" => "The task has a bounded, safe, and useful review scope."
      })

    task
  end
end
