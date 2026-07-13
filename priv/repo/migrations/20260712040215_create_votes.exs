defmodule Tarakan.Repo.Migrations.CreateVotes do
  use Ecto.Migration

  def change do
    create table(:votes) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      # Polymorphic by (subject_type, subject_id): "finding" -> scan_findings,
      # "comment" -> finding_comments. Kept generic so new votable kinds don't
      # need a new table.
      add :subject_type, :string, null: false
      add :subject_id, :bigint, null: false
      add :value, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One standing vote per account per item; recasting updates value.
    create unique_index(:votes, [:account_id, :subject_type, :subject_id])
    create index(:votes, [:subject_type, :subject_id])
    create constraint(:votes, :votes_value_must_be_unit, check: "value IN (-1, 1)")
  end
end
