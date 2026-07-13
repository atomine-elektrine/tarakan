defmodule Tarakan.Repo.Migrations.CreateReviewStakes do
  use Ecto.Migration

  def change do
    create table(:review_stakes) do
      add :scan_id, references(:scans, on_delete: :delete_all), null: false
      # Denormalized submitter so reputation queries don't join back to scans.
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :amount, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One standing stake per review.
    create unique_index(:review_stakes, [:scan_id])
    create index(:review_stakes, [:account_id])
    create constraint(:review_stakes, :review_stakes_amount_positive, check: "amount >= 0")
  end
end
