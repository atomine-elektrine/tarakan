defmodule Tarakan.Repo.Migrations.LinkReviewTasksAndScans do
  @moduledoc """
  Additive FKs for the Review/Request domain collapse (PR 1a).

  - `review_tasks.linked_review_id` → the latest Review created when completing a Request
  - `scans.source_request_id` → the Request that produced this Review (history of attempts)

  No application behavior change in this migration. Both columns are nullable so
  existing rows and ad-hoc Reviews remain valid.
  """

  use Ecto.Migration

  def change do
    alter table(:scans) do
      add :source_request_id, references(:review_tasks, on_delete: :nilify_all)
    end

    alter table(:review_tasks) do
      add :linked_review_id, references(:scans, on_delete: :nilify_all)
    end

    create index(:scans, [:source_request_id])
    create index(:review_tasks, [:linked_review_id])
  end
end
