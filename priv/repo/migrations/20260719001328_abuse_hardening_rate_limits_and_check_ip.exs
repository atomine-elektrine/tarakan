defmodule Tarakan.Repo.Migrations.AbuseHardeningRateLimitsAndCheckIp do
  use Ecto.Migration

  def change do
    create table(:rate_limit_buckets, primary_key: false) do
      add :key, :text, null: false, primary_key: true
      add :bucket, :bigint, null: false, primary_key: true
      add :count, :integer, null: false, default: 0
      add :expires_at, :bigint, null: false
    end

    create index(:rate_limit_buckets, [:expires_at])

    alter table(:canonical_finding_checks) do
      add :client_ip_hash, :binary
    end

    create index(:canonical_finding_checks, [:client_ip_hash],
             where: "client_ip_hash IS NOT NULL"
           )

    alter table(:scan_confirmations) do
      add :client_ip_hash, :binary
    end

    create index(:scan_confirmations, [:client_ip_hash], where: "client_ip_hash IS NOT NULL")
  end
end
