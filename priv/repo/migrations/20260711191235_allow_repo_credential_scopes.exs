defmodule Tarakan.Repo.Migrations.AllowRepoCredentialScopes do
  use Ecto.Migration

  @with_repo "scopes <@ ARRAY['tasks:read', 'tasks:claim', 'contributions:write', 'findings:submit', 'reports:write', 'reviews:read', 'reviews:verify', 'repo:read', 'repo:write']::varchar[]"
  @without_repo "scopes <@ ARRAY['tasks:read', 'tasks:claim', 'contributions:write', 'findings:submit', 'reports:write', 'reviews:read', 'reviews:verify']::varchar[]"

  def up do
    drop constraint(:api_credentials, :api_credentials_scopes_must_be_valid)

    create constraint(:api_credentials, :api_credentials_scopes_must_be_valid, check: @with_repo)
  end

  def down do
    drop constraint(:api_credentials, :api_credentials_scopes_must_be_valid)

    create constraint(:api_credentials, :api_credentials_scopes_must_be_valid,
             check: @without_repo
           )
  end
end
