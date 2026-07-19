defmodule Tarakan.Repo.Migrations.AddPatternKeyToCanonicalFindings do
  use Ecto.Migration

  import Ecto.Query

  def up do
    alter table(:canonical_findings) do
      add :pattern_key, :string, size: 64
    end

    create index(:canonical_findings, [:pattern_key])
    create index(:canonical_findings, [:fingerprint])

    flush()
    backfill_pattern_keys()
  end

  def down do
    drop_if_exists index(:canonical_findings, [:fingerprint])
    drop_if_exists index(:canonical_findings, [:pattern_key])

    alter table(:canonical_findings) do
      remove :pattern_key
    end
  end

  defp backfill_pattern_keys do
    # Keep migration self-contained (no app module dependency at migrate time).
    normalize = fn value ->
      value
      |> to_string()
      |> String.downcase()
      |> String.replace(
        ~r/^(verified|hypothesis(?:\/low)?|unverified|likely|possible|confirmed)\s*:\s*/iu,
        ""
      )
      |> String.replace(~r/[^\p{L}\p{N}\s\/\.\-_]/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
    end

    pattern_key = fn title ->
      title
      |> normalize.()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    rows =
      repo().all(
        from(c in "canonical_findings",
          where: is_nil(c.pattern_key),
          select: {c.id, c.title}
        )
      )

    Enum.each(rows, fn {id, title} ->
      repo().query!(
        "UPDATE canonical_findings SET pattern_key = $1 WHERE id = $2",
        [pattern_key.(title), id]
      )
    end)
  end
end
