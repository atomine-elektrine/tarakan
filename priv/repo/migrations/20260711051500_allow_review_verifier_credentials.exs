defmodule Tarakan.Repo.Migrations.AllowReviewVerifierCredentials do
  use Ecto.Migration

  @with_reviews "scopes <@ ARRAY['tasks:read', 'tasks:claim', 'contributions:write', 'findings:submit', 'reports:write', 'reviews:read', 'reviews:verify']::varchar[]"
  @without_reviews "scopes <@ ARRAY['tasks:read', 'tasks:claim', 'contributions:write', 'findings:submit', 'reports:write']::varchar[]"

  def up do
    drop constraint(:api_credentials, :api_credentials_scopes_must_be_valid)

    create constraint(:api_credentials, :api_credentials_scopes_must_be_valid,
             check: @with_reviews
           )
  end

  def down do
    drop constraint(:api_credentials, :api_credentials_scopes_must_be_valid)

    create constraint(:api_credentials, :api_credentials_scopes_must_be_valid,
             check: @without_reviews
           )
  end
end
