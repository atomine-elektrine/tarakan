defmodule Tarakan.Repositories.Repository do
  @moduledoc """
  A canonical public repository registered with Tarakan.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.{Account, Identity}
  alias Tarakan.Repositories.RepositoryMembership

  @participation_modes ~w(unclaimed community maintainer_verified curated paused)
  @listing_statuses ~w(pending listed quarantined)
  @hosted_host "tarakan.lol"

  schema "repositories" do
    field :host, :string, default: "github.com"
    field :owner, :string
    field :name, :string
    field :canonical_url, :string
    field :status, :string, default: "unscanned"
    field :scan_count, :integer, default: 0
    field :open_findings_count, :integer, default: 0
    field :verified_findings_count, :integer, default: 0
    field :last_scanned_at, :utc_datetime_usec
    field :github_id, :integer
    field :node_id, :string
    field :default_branch, :string
    field :description, :string
    field :primary_language, :string
    field :stars_count, :integer, default: 0
    field :forks_count, :integer, default: 0
    field :archived, :boolean, default: false
    field :last_synced_at, :utc_datetime_usec
    field :participation_mode, :string, default: "unclaimed"
    field :listing_status, :string, default: "listed"
    field :pushed_at, :utc_datetime_usec
    field :disk_size_bytes, :integer, default: 0

    belongs_to :submitted_by, Account
    belongs_to :submitted_by_identity, Identity
    has_many :memberships, RepositoryMembership

    timestamps(type: :utc_datetime_usec)
  end

  def participation_modes, do: @participation_modes
  def listing_statuses, do: @listing_statuses

  @doc "The canonical host value for repositories hosted on Tarakan itself."
  def hosted_host, do: @hosted_host

  def hosted?(%__MODULE__{host: @hosted_host}), do: true
  def hosted?(_repository), do: false

  @doc """
  Changeset for a repository hosted on Tarakan itself.

  The owner is always the creating account's handle; identity is pinned to
  the hosted host and never carries GitHub metadata.
  """
  def hosted_changeset(repository, attrs, owner) when is_binary(owner) do
    repository
    |> cast(attrs, [:name])
    |> update_change(:name, &normalize/1)
    |> put_change(:host, @hosted_host)
    |> put_change(:owner, owner)
    |> validate_required([:host, :owner, :name])
    |> validate_format(:name, ~r/^[a-z0-9._-]+$/,
      message: "may only contain letters, digits, and . _ -"
    )
    |> validate_length(:name, max: 100)
    |> validate_hosted_name()
    |> put_hosted_canonical_url()
    |> unique_constraint([:host, :owner, :name],
      name: :repositories_host_owner_name_index,
      message: "is already one of your repositories"
    )
  end

  defp validate_hosted_name(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      cond do
        name in [".", ".."] -> [name: "is reserved"]
        String.ends_with?(name, ".git") -> [name: "may not end in .git"]
        String.starts_with?(name, ".") -> [name: "may not start with a dot"]
        true -> []
      end
    end)
  end

  defp put_hosted_canonical_url(changeset) do
    case get_field(changeset, :name) do
      name when is_binary(name) and name != "" ->
        owner = get_field(changeset, :owner)
        put_change(changeset, :canonical_url, "https://#{@hosted_host}/#{owner}/#{name}")

      _missing ->
        changeset
    end
  end

  @doc false
  def listing_changeset(repository, attrs) do
    repository
    |> cast(attrs, [:listing_status])
    |> validate_required([:listing_status])
    |> validate_inclusion(:listing_status, @listing_statuses)
    |> check_constraint(:listing_status, name: :repositories_listing_status_must_be_valid)
  end

  @doc false
  def participation_changeset(repository, attrs) do
    repository
    |> cast(attrs, [:participation_mode])
    |> validate_required([:participation_mode])
    |> validate_inclusion(:participation_mode, @participation_modes)
    |> check_constraint(:participation_mode,
      name: :repositories_participation_mode_must_be_valid
    )
  end

  @doc false
  def github_metadata_changeset(repository, metadata, %Account{} = submitter) do
    repository
    |> registration_changeset(metadata)
    |> put_change(:github_id, metadata.github_id)
    |> put_node_id(metadata)
    |> put_change(:canonical_url, metadata.canonical_url)
    |> put_change(:default_branch, metadata.default_branch)
    |> put_change(:description, metadata.description)
    |> put_change(:primary_language, metadata.primary_language)
    |> put_change(:stars_count, metadata.stars_count)
    |> put_change(:forks_count, metadata.forks_count)
    |> put_change(:archived, metadata.archived)
    |> put_change(:last_synced_at, metadata.last_synced_at)
    |> maybe_put_submitter(repository, submitter)
    |> validate_required([:github_id, :canonical_url, :last_synced_at])
    |> unique_constraint(:github_id)
  end

  @doc """
  Adopts the host's current canonical identity for an already-registered
  repository (rename or transfer). Never touches the submitter.
  """
  def canonical_identity_changeset(repository, metadata) do
    repository
    |> registration_changeset(%{host: metadata.host, owner: metadata.owner, name: metadata.name})
    |> put_node_id(metadata)
    |> put_change(:canonical_url, metadata.canonical_url)
    |> put_change(:default_branch, metadata.default_branch)
    |> put_change(:description, metadata.description)
    |> put_change(:primary_language, metadata.primary_language)
    |> put_change(:stars_count, metadata.stars_count)
    |> put_change(:forks_count, metadata.forks_count)
    |> put_change(:archived, metadata.archived)
    |> put_change(:last_synced_at, metadata.last_synced_at)
    |> validate_required([:canonical_url, :last_synced_at])
  end

  @doc false
  def registration_changeset(repository, attrs) do
    repository
    |> cast(attrs, [:host, :owner, :name])
    |> update_change(:host, &normalize/1)
    |> update_change(:owner, &normalize/1)
    |> update_change(:name, &normalize/1)
    |> validate_required([:host, :owner, :name])
    |> validate_inclusion(:host, ["github.com"])
    |> validate_format(:owner, ~r/^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$/,
      message: "is not a valid GitHub owner"
    )
    |> validate_format(:name, ~r/^[a-z0-9._-]+$/,
      message: "is not a valid GitHub repository name"
    )
    |> validate_length(:name, max: 100)
    |> put_canonical_url()
    |> unique_constraint([:host, :owner, :name],
      name: :repositories_host_owner_name_index,
      message: "has already been registered"
    )
  end

  defp normalize(value), do: value |> String.trim() |> String.downcase()

  defp put_node_id(changeset, metadata) do
    case Map.get(metadata, :node_id) do
      node_id when is_binary(node_id) and node_id != "" ->
        changeset
        |> put_change(:node_id, node_id)
        |> unique_constraint(:node_id)

      _missing ->
        changeset
    end
  end

  defp maybe_put_submitter(changeset, %{submitted_by_id: nil}, submitter) do
    put_change(changeset, :submitted_by_id, submitter.id)
  end

  defp maybe_put_submitter(changeset, _repository, _submitter), do: changeset

  defp put_canonical_url(changeset) do
    owner = get_field(changeset, :owner)
    name = get_field(changeset, :name)

    if is_binary(owner) and owner != "" and is_binary(name) and name != "" do
      put_change(changeset, :canonical_url, "https://github.com/#{owner}/#{name}")
    else
      changeset
    end
  end
end
