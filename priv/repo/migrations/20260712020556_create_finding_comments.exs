defmodule Tarakan.Repo.Migrations.CreateFindingComments do
  use Ecto.Migration

  def change do
    create table(:finding_comments) do
      add :finding_id, references(:scan_findings, on_delete: :delete_all), null: false
      # Denormalized so authorization, moderation, and PubSub scoping never
      # need to walk finding -> scan -> repository.
      add :repository_id, references(:repositories, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, on_delete: :restrict), null: false
      add :parent_id, references(:finding_comments, on_delete: :delete_all)
      add :body, :text, null: false

      # Moderation is takedown, not a visibility gate: a removed comment keeps
      # its place in the thread and renders as a placeholder.
      add :removed_at, :utc_datetime_usec
      add :removed_by_id, references(:accounts, on_delete: :nilify_all)
      add :removed_reason, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:finding_comments, [:finding_id, :inserted_at])
    create index(:finding_comments, [:parent_id])
    create index(:finding_comments, [:account_id])
  end
end
