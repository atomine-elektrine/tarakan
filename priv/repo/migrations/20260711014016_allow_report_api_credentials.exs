defmodule Tarakan.Repo.Migrations.AllowReportApiCredentials do
  use Ecto.Migration

  def up do
    drop constraint(:api_credentials, :api_credentials_scopes_must_be_valid)

    create constraint(:api_credentials, :api_credentials_scopes_must_be_valid,
             check:
               "scopes <@ ARRAY['tasks:read', 'tasks:claim', 'contributions:write', 'findings:submit', 'reports:write']::varchar[]"
           )
  end

  def down do
    drop constraint(:api_credentials, :api_credentials_scopes_must_be_valid)

    create constraint(:api_credentials, :api_credentials_scopes_must_be_valid,
             check:
               "scopes <@ ARRAY['tasks:read', 'tasks:claim', 'contributions:write', 'findings:submit']::varchar[]"
           )
  end
end
