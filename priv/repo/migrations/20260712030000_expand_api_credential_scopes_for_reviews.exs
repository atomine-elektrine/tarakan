defmodule Tarakan.Repo.Migrations.ExpandApiCredentialScopesForReviews do
  use Ecto.Migration

  @with_all """
  scopes <@ ARRAY[
    'tasks:read', 'tasks:claim', 'contributions:write',
    'findings:submit', 'findings:verify', 'findings:read',
    'reviews:submit', 'reviews:read', 'reviews:verify',
    'reports:write', 'repo:read', 'repo:write', 'discussion:write',
    'requests:read', 'requests:claim'
  ]::varchar[]
  """

  @previous """
  scopes <@ ARRAY[
    'tasks:read', 'tasks:claim', 'contributions:write', 'findings:submit',
    'reports:write', 'reviews:read', 'reviews:verify', 'repo:read', 'repo:write'
  ]::varchar[]
  """

  def up do
    drop constraint(:api_credentials, :api_credentials_scopes_must_be_valid)

    create constraint(:api_credentials, :api_credentials_scopes_must_be_valid, check: @with_all)
  end

  def down do
    drop constraint(:api_credentials, :api_credentials_scopes_must_be_valid)

    create constraint(:api_credentials, :api_credentials_scopes_must_be_valid, check: @previous)
  end
end
