defmodule Tarakan.Repo.Migrations.AutoPublicDisclosure do
  use Ecto.Migration

  @moduledoc """
  Disclosure is automatic: reviews, findings, tasks, and repository records
  are public the moment they exist. Verification and moderation still run,
  but they only change status labels. `restricted` visibility and repository
  quarantine remain as explicit moderation takedowns.
  """

  def up do
    drop constraint(:scans, :scans_publication_requires_acceptance)

    alter table(:scans) do
      modify :visibility, :string, null: false, default: "public"
    end

    execute "UPDATE scans SET visibility = 'public'"

    alter table(:repositories) do
      modify :listing_status, :string, null: false, default: "listed"
    end

    execute "UPDATE repositories SET listing_status = 'listed' WHERE listing_status = 'pending'"

    drop constraint(:review_tasks, :review_tasks_visibility_must_match_state)
    drop constraint(:review_tasks, :review_tasks_disclosure_must_be_attributed)
    drop constraint(:review_tasks, :review_tasks_full_disclosure_requires_sensitive_review)

    alter table(:review_tasks) do
      modify :visibility, :string, null: false, default: "public"
    end

    # Cancelled tasks stay restricted: moderation quarantine lands in that
    # state and cannot be told apart from an ordinary cancellation here.
    execute "UPDATE review_tasks SET visibility = 'public' WHERE status != 'cancelled'"
  end

  def down do
    alter table(:review_tasks) do
      modify :visibility, :string, null: false, default: "restricted"
    end

    # The state-coupled disclosure constraints cannot be recreated without
    # re-restricting already-public rows; reset visibility first.
    execute "UPDATE review_tasks SET visibility = 'restricted'"

    create constraint(:review_tasks, :review_tasks_visibility_must_match_state,
             check:
               "visibility = 'restricted' OR " <>
                 "(visibility = 'public_summary' AND status IN ('open', 'claimed', 'accepted')) OR " <>
                 "(visibility = 'public' AND status = 'accepted')"
           )

    create constraint(:review_tasks, :review_tasks_disclosure_must_be_attributed,
             check:
               "visibility = 'restricted' OR (disclosed_at IS NOT NULL AND disclosed_by_id IS NOT NULL)"
           )

    create constraint(:review_tasks, :review_tasks_full_disclosure_requires_sensitive_review,
             check:
               "visibility != 'public' OR " <>
                 "(sensitive_data_reviewed_at IS NOT NULL AND sensitive_data_reviewed_by_id IS NOT NULL)"
           )

    alter table(:repositories) do
      modify :listing_status, :string, null: false, default: "pending"
    end

    alter table(:scans) do
      modify :visibility, :string, null: false, default: "restricted"
    end

    # Already-published rows stay public; re-restricting them here would
    # claim a disclosure decision that never happened.
    execute """
    UPDATE scans SET visibility = 'restricted'
    WHERE review_status != 'accepted'
    """

    create constraint(:scans, :scans_publication_requires_acceptance,
             check: "visibility = 'restricted' OR review_status = 'accepted'"
           )
  end
end
