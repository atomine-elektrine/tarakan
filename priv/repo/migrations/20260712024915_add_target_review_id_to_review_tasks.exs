defmodule Tarakan.Repo.Migrations.AddTargetReviewIdToReviewTasks do
  @moduledoc """
  PR5.1: verify_findings Requests point at the Review they are verifying.
  """

  use Ecto.Migration

  def change do
    alter table(:review_tasks) do
      add :target_review_id, references(:scans, on_delete: :nilify_all)
    end

    create index(:review_tasks, [:target_review_id])
  end
end
