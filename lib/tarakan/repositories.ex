defmodule Tarakan.Repositories do
  @moduledoc """
  The public repository registry.
  """

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Tarakan.Accounts
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Audit
  alias Tarakan.GitHub
  alias Tarakan.Moderation.Holds
  alias Tarakan.Policy
  alias Tarakan.Repo
  alias Tarakan.Repositories.{Repository, RepositoryMembership}
  alias Tarakan.Scans

  @registration_types %{url: :string}
  @topic "repositories"

  @doc """
  Subscribes the caller to registry events.

  Subscribers receive `{:repository_registered, %Repository{}}` whenever a
  repository enters the public record for the first time, and
  `{:repository_record_updated, %Repository{}}` whenever scan activity
  changes a repository's security record.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(Tarakan.PubSub, @topic)
  end

  @doc """
  Broadcasts that scan activity changed `repository`'s security record, so
  registry-level dashboards can refresh their aggregates.
  """
  def broadcast_record_updated(%Repository{} = repository) do
    invalidate_registry_stats()
    broadcast({:repository_record_updated, repository})
  end

  @doc "Broadcasts the first transition of a repository into the public registry."
  def broadcast_registration(%Repository{listing_status: "listed"} = repository) do
    invalidate_registry_stats()
    broadcast({:repository_registered, repository})
  end

  def broadcast_registration(%Repository{}), do: :ok

  def count_repositories do
    Repo.aggregate(Repository, :count)
  end

  @doc """
  Searches publicly listed repositories by owner, name, or `owner/name`.

  Matching is a case-insensitive substring match; blank queries return no
  results. Name-prefix matches sort ahead of the rest, then most recently
  registered first.
  """
  def search_repositories(query, limit \\ 20)

  def search_repositories(query, limit) when is_binary(query) do
    case String.trim(query) do
      "" ->
        []

      term ->
        limit = limit |> min(50) |> max(1)
        escaped = escape_like_pattern(term)
        pattern = "%" <> escaped <> "%"
        prefix = escaped <> "%"

        Repository
        |> where([repository], repository.listing_status == "listed")
        |> where(
          [repository],
          ilike(repository.owner, ^pattern) or ilike(repository.name, ^pattern) or
            ilike(fragment("? || '/' || ?", repository.owner, repository.name), ^pattern)
        )
        |> order_by([repository],
          desc: ilike(repository.name, ^prefix),
          desc: repository.inserted_at
        )
        |> limit(^limit)
        |> Repo.all()
    end
  end

  def search_repositories(_query, _limit), do: []

  defp escape_like_pattern(term) do
    String.replace(term, ["\\", "%", "_"], fn char -> "\\" <> char end)
  end

  @doc "Cursor page of listed repositories (id ascending)."
  def list_listed_repositories_page(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 1_000) |> max(1) |> min(5_000)
    after_id = Keyword.get(opts, :after_id, 0)

    repos =
      Repository
      |> where(
        [repository],
        repository.listing_status == "listed" and repository.id > ^after_id
      )
      |> order_by([repository], asc: repository.id)
      |> limit(^limit)
      |> Repo.all()

    next_after_id =
      case List.last(repos) do
        %Repository{id: id} -> id
        _ -> nil
      end

    %{repositories: repos, next_after_id: next_after_id}
  end

  @doc "Lazy stream of listed repositories for SEO/export."
  def stream_listed_repositories(opts \\ []) do
    Stream.resource(
      fn -> 0 end,
      fn
        nil ->
          {:halt, nil}

        after_id ->
          %{repositories: repos, next_after_id: next} =
            list_listed_repositories_page(Keyword.merge(opts, after_id: after_id))

          case repos do
            [] -> {:halt, nil}
            _ -> {repos, next}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc false
  def list_listed_repositories do
    stream_listed_repositories() |> Enum.to_list()
  end

  @doc """
  Lists repositories for review clients as an authenticated work queue.

  Includes `pending` repositories (registered, no disclosed review yet) as well
  as `listed` ones, because the pending set is precisely the work a scanning
  client needs to pick up. `quarantined` repositories (moderator-paused) are
  excluded. `status: "unscanned"` narrows to repositories with no disclosed,
  verified review - the front of the queue.
  """
  def list_reviewable_repositories(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> min(500) |> max(1)

    # :all includes pending repositories - appropriate for the authenticated
    # client API, where reviewers can open them. Anonymous surfaces (the
    # homepage queue) must pass listing: :listed or they link to records the
    # viewer cannot see.
    listing_statuses =
      case Keyword.get(opts, :listing, :all) do
        :listed -> ["listed"]
        :all -> ["pending", "listed"]
      end

    Repository
    |> where([repository], repository.listing_status in ^listing_statuses)
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> order_by([repository],
      desc: repository.status == "unscanned",
      desc: repository.inserted_at
    )
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_status(query, status) when status in ~w(unscanned findings reviewed clear) do
    where(query, [repository], repository.status == ^status)
  end

  defp maybe_filter_status(query, _status), do: query

  @doc "Lists all repository relationship records for an account."
  def list_account_memberships(%Account{id: account_id}) do
    RepositoryMembership
    |> where([membership], membership.account_id == ^account_id)
    |> order_by([membership], asc: membership.repository_id)
    |> Repo.all()
  end

  @doc """
  Proposes a repository relationship. The relationship grants no authority
  until a steward or moderator verifies it.
  """
  def propose_repository_membership(
        %Scope{} = scope,
        %Repository{} = repository,
        %Account{} = account,
        attrs
      ) do
    transact_repository_with_target(scope, repository.id, account.id, fn
      fresh_scope, canonical_repository, canonical_account ->
        with :ok <-
               Policy.authorize(
                 fresh_scope,
                 :propose_repository_membership,
                 canonical_repository
               ),
             true <-
               fresh_scope.account_id == canonical_account.id or
                 Policy.allowed?(
                   fresh_scope,
                   :manage_repository_memberships,
                   canonical_repository
                 ) do
          result =
            %RepositoryMembership{
              repository_id: canonical_repository.id,
              account_id: canonical_account.id
            }
            |> RepositoryMembership.changeset(attrs)
            |> Repo.insert()

          with {:ok, membership} <- result do
            audit!(fresh_scope, :repository_membership_proposed, membership, %{
              from_state: nil,
              to_state: membership.status,
              metadata: %{role: membership.role}
            })

            {:ok, membership}
          end
        else
          false -> {:error, :unauthorized}
          error -> error
        end
    end)
  end

  @doc "Verifies, revokes, or returns a relationship to pending review."
  def set_repository_membership_status(
        %Scope{} = scope,
        %RepositoryMembership{} = membership,
        status
      ) do
    transact_membership_authorized(scope, membership.id, fn fresh_scope, canonical_membership ->
      status = to_string(status)

      with :ok <-
             Policy.authorize(
               fresh_scope,
               :verify_repository_membership,
               canonical_membership
             ),
           :ok <- prevent_self_verification(fresh_scope, canonical_membership, status),
           {:ok, updated} <-
             canonical_membership
             |> RepositoryMembership.status_changeset(status, fresh_scope.account)
             |> Repo.update() do
        audit!(fresh_scope, :repository_membership_status_changed, updated, %{
          from_state: canonical_membership.status,
          to_state: updated.status,
          metadata: %{role: updated.role}
        })

        {:ok, updated}
      end
    end)
    |> notify_membership_authorization_change()
  end

  @doc "Changes how community participation is handled for a repository."
  def update_participation_mode(%Scope{} = scope, %Repository{} = repository, attrs) do
    transact_repository_authorized(scope, repository.id, fn fresh_scope, canonical_repository ->
      with :ok <- Policy.authorize(fresh_scope, :manage_repository, canonical_repository),
           :ok <- repository_hold_allows_mode(fresh_scope, canonical_repository, attrs),
           :ok <- authorize_participation_mode(fresh_scope, attrs),
           {:ok, updated} <-
             canonical_repository
             |> Repository.participation_changeset(attrs)
             |> Repo.update() do
        audit!(fresh_scope, :repository_participation_mode_updated, updated, %{
          from_state: canonical_repository.participation_mode,
          to_state: updated.participation_mode
        })

        {:ok, updated}
      end
    end)
    |> notify_repository_update()
  end

  @doc "Changes whether a repository is pending, globally listed, or quarantined."
  def update_listing_status(%Scope{} = scope, %Repository{} = repository, status) do
    status = to_string(status)
    previous_status = repository.listing_status

    result =
      transact_repository_authorized(scope, repository.id, fn fresh_scope, canonical_repository ->
        with :ok <- Policy.authorize(fresh_scope, :manage_repository, canonical_repository),
             :ok <- repository_hold_allows_listing(fresh_scope, canonical_repository, status),
             {:ok, updated} <-
               canonical_repository
               |> Repository.listing_changeset(%{listing_status: status})
               |> Repo.update() do
          audit!(fresh_scope, :repository_listing_status_updated, updated, %{
            from_state: canonical_repository.listing_status,
            to_state: updated.listing_status
          })

          {:ok, updated}
        end
      end)

    case result do
      {:ok, %Repository{} = updated} = ok ->
        if previous_status != updated.listing_status do
          _ =
            Tarakan.Epidemics.schedule_refresh_for_repository_after_commit(updated.id,
              reason: :listing_change
            )
        end

        notify_repository_update(ok)

      other ->
        other
    end
  end

  @doc """
  Aggregate state of the registry, for the public dashboard.
  Cached in ETS for 30s (PR 8).
  """
  def registry_stats do
    ttl = registry_stats_ttl()

    if ttl <= 0 do
      load_registry_stats()
    else
      now = System.system_time(:second)
      table = registry_stats_table()

      case :ets.lookup(table, :stats) do
        [{:stats, stats, expires_at}] when expires_at > now ->
          stats

        _ ->
          stats = load_registry_stats()
          true = :ets.insert(table, {:stats, stats, now + ttl})
          stats
      end
    end
  end

  @doc "Drop ETS cache after registry mutations so dashboards stay live."
  def invalidate_registry_stats do
    case :ets.whereis(:tarakan_registry_stats) do
      :undefined -> :ok
      _tid -> :ets.delete(:tarakan_registry_stats, :stats)
    end

    :ok
  end

  defp registry_stats_ttl do
    Application.get_env(:tarakan, :registry_stats_ttl_seconds, 30)
  end

  defp load_registry_stats do
    Repo.one(
      from repository in Repository,
        where: repository.listing_status == "listed",
        select: %{
          repositories: count(repository.id),
          unscanned: count(repository.id) |> filter(repository.status == "unscanned"),
          open_findings: coalesce(sum(repository.open_findings_count), 0),
          verified_findings: coalesce(sum(repository.verified_findings_count), 0)
        }
    ) ||
      %{repositories: 0, unscanned: 0, open_findings: 0, verified_findings: 0}
  end

  defp registry_stats_table do
    case :ets.whereis(:tarakan_registry_stats) do
      :undefined ->
        try do
          :ets.new(:tarakan_registry_stats, [
            :named_table,
            :public,
            :set,
            read_concurrency: true
          ])
        rescue
          ArgumentError -> :tarakan_registry_stats
        end

      _tid ->
        :tarakan_registry_stats
    end
  end

  def get_repository(host, owner, name)
      when is_binary(host) and is_binary(owner) and is_binary(name) do
    Repository
    |> Repo.get_by(
      host: host,
      owner: String.downcase(owner),
      name: String.downcase(name)
    )
    |> Repo.preload(:submitted_by)
  end

  def get_visible_repository(host, owner, name, scope) do
    case get_repository(host, owner, name) do
      %Repository{} = repository ->
        if repository_visible?(repository, scope), do: repository

      nil ->
        nil
    end
  end

  def get_github_repository(owner, name), do: get_repository("github.com", owner, name)

  def get_visible_github_repository(owner, name, scope),
    do: get_visible_repository("github.com", owner, name, scope)

  @doc """
  Adopts the host's current canonical identity for a repository that was
  renamed or transferred upstream. The caller must have re-resolved the
  metadata through the immutable host id; anything else is rejected.
  """
  def adopt_canonical_identity(%Repository{} = repository, %{github_id: github_id} = metadata)
      when is_integer(github_id) and github_id == repository.github_id do
    repository
    |> Repository.canonical_identity_changeset(metadata)
    |> Repo.update()
    |> case do
      {:ok, updated_repository} ->
        broadcast_record_updated(updated_repository)
        {:ok, updated_repository}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def adopt_canonical_identity(%Repository{}, _metadata), do: {:error, :identity_changed}

  def register_github_repository(input, %Account{} = submitter) when is_binary(input) do
    register_github_repository(input, Scope.for_account(submitter))
  end

  def register_github_repository(input, %Scope{account: %Account{}} = scope)
      when is_binary(input) do
    with :ok <- Policy.authorize(scope, :register_repository),
         {:ok, identity} <- parse_github_repository(input) do
      case find_existing_identity(identity) do
        %Repository{} = repository ->
          {:ok, Repo.preload(repository, :submitted_by)}

        nil ->
          with :ok <- repository_fetch_preflight(scope),
               {:ok, metadata} <- GitHub.fetch_public_repository(identity.owner, identity.name) do
            persist_github_repository(metadata, scope)
          end
      end
    end
  end

  def register_github_repository(_input, _scope), do: {:error, :unauthorized}

  defp persist_github_repository(metadata, scope) do
    case find_existing_repository(metadata) do
      %Repository{id: nil} = repository ->
        insert_registered_repository(repository, metadata, scope)

      %Repository{} = repository ->
        repository
        |> Repository.github_metadata_changeset(metadata, scope.account)
        |> Repo.update()
    end
  end

  defp insert_registered_repository(repository, metadata, scope) do
    Multi.new()
    |> Multi.run(:authorization, fn repo, _changes ->
      account =
        repo.one!(
          from account in Account,
            where: account.id == ^scope.account_id,
            lock: "FOR UPDATE"
        )

      fresh_scope =
        case Accounts.refresh_scope_for_account(account, scope) do
          {:ok, fresh_scope} -> fresh_scope
          {:error, reason} -> repo.rollback(reason)
        end

      with :ok <- Policy.authorize(fresh_scope, :register_repository),
           :ok <- registration_quota(repo, account) do
        {:ok, %{account: account, scope: fresh_scope}}
      end
    end)
    |> Multi.insert(:repository, fn %{authorization: %{account: account}} ->
      Repository.github_metadata_changeset(repository, metadata, account)
    end)
    |> Multi.insert(:audit, fn %{
                                 authorization: %{scope: fresh_scope},
                                 repository: inserted_repository
                               } ->
      Audit.event_changeset(fresh_scope, :repository_registered, inserted_repository, %{
        from_state: nil,
        to_state: inserted_repository.participation_mode
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{repository: inserted_repository}} ->
        broadcast_registration(inserted_repository)
        Tarakan.Activity.broadcast_registration(inserted_repository)
        {:ok, inserted_repository}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc false
  def registration_quota(_repo, %Account{platform_role: role})
      when role in ["moderator", "admin"],
      do: :ok

  def registration_quota(repo, %Account{} = account) do
    cutoff = DateTime.add(DateTime.utc_now(), -1, :day)

    count =
      repo.aggregate(
        from(repository in Repository,
          where: repository.submitted_by_id == ^account.id and repository.inserted_at >= ^cutoff
        ),
        :count
      )

    limit = if account.trust_tier == "reviewer", do: 50, else: registration_limit(account.state)

    if count < limit, do: :ok, else: {:error, :registration_limit}
  end

  defp registration_limit("probation"), do: 5
  defp registration_limit("active"), do: 25
  defp registration_limit(_state), do: 0

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Tarakan.PubSub, @topic, message)
  end

  def registration_changeset(attrs \\ %{}) do
    {%{}, @registration_types}
    |> cast(attrs, Map.keys(@registration_types))
    |> validate_required([:url])
  end

  def parse_github_repository(input) when is_binary(input) do
    input
    |> String.trim()
    |> parse_repository_reference()
  end

  defp parse_repository_reference(""), do: {:error, :invalid_github_repository}

  defp parse_repository_reference(input) do
    case Regex.run(~r/^git@github\.com:([^\/]+)\/([^\/]+?)(?:\.git)?$/, input,
           capture: :all_but_first
         ) do
      [owner, name] -> valid_identity(owner, name)
      nil -> parse_repository_url(input)
    end
  end

  defp parse_repository_url(input) do
    normalized_input =
      cond do
        String.starts_with?(input, ["https://", "http://"]) -> input
        String.starts_with?(input, ["github.com/", "www.github.com/"]) -> "https://#{input}"
        true -> "https://github.com/#{input}"
      end

    uri = URI.parse(normalized_input)
    host = uri.host && String.downcase(uri.host)
    segments = uri.path |> to_string() |> String.split("/", trim: true)

    case {host, segments} do
      {host, [owner, name]} when host in ["github.com", "www.github.com"] ->
        valid_identity(owner, String.trim_trailing(name, ".git"))

      _other ->
        {:error, :invalid_github_repository}
    end
  end

  defp valid_identity(owner, name) do
    changeset =
      Repository.registration_changeset(%Repository{}, %{
        host: "github.com",
        owner: owner,
        name: name
      })

    if changeset.valid? do
      {:ok,
       %{
         host: "github.com",
         owner: get_field(changeset, :owner),
         name: get_field(changeset, :name)
       }}
    else
      {:error, :invalid_github_repository}
    end
  end

  defp find_existing_repository(metadata) do
    Repo.get_by(Repository, github_id: metadata.github_id) ||
      Repo.get_by(Repository,
        host: "github.com",
        owner: String.downcase(metadata.owner),
        name: String.downcase(metadata.name)
      ) || %Repository{}
  end

  defp find_existing_identity(identity) do
    Repo.get_by(Repository,
      host: "github.com",
      owner: String.downcase(identity.owner),
      name: String.downcase(identity.name)
    )
  end

  defp repository_fetch_preflight(%Scope{account_id: account_id}) do
    case Tarakan.RateLimiter.check({:repository_fetch, account_id}, 10, 60) do
      :ok -> :ok
      {:error, _reason, _retry_after} -> {:error, :request_limited}
    end
  end

  defp transact_repository_authorized(%Scope{} = scope, repository_id, fun)
       when is_function(fun, 2) do
    Repo.transaction(fn ->
      repository = lock_repository(repository_id) || Repo.rollback(:not_found)
      fresh_scope = lock_scope(scope)

      unwrap_transaction_result(fun.(fresh_scope, repository))
    end)
  end

  defp transact_repository_with_target(%Scope{} = scope, repository_id, target_account_id, fun)
       when is_function(fun, 3) do
    Repo.transaction(fn ->
      repository = lock_repository(repository_id) || Repo.rollback(:not_found)
      target_account = lock_account(target_account_id) || Repo.rollback(:not_found)
      fresh_scope = lock_scope(scope)

      unwrap_transaction_result(fun.(fresh_scope, repository, target_account))
    end)
  end

  defp transact_membership_authorized(%Scope{} = scope, membership_id, fun)
       when is_function(fun, 2) do
    Repo.transaction(fn ->
      membership = Repo.get(RepositoryMembership, membership_id) || Repo.rollback(:not_found)
      _repository = lock_repository(membership.repository_id) || Repo.rollback(:not_found)
      _target_account = lock_account(membership.account_id) || Repo.rollback(:not_found)
      fresh_scope = lock_scope(scope)

      canonical_membership = lock_membership(membership_id) || Repo.rollback(:not_found)

      if canonical_membership.repository_id != membership.repository_id or
           canonical_membership.account_id != membership.account_id do
        Repo.rollback(:not_found)
      end

      unwrap_transaction_result(fun.(fresh_scope, canonical_membership))
    end)
  end

  defp unwrap_transaction_result({:ok, result}), do: result
  defp unwrap_transaction_result({:error, reason}), do: Repo.rollback(reason)

  defp lock_account(id) when is_integer(id) do
    Repo.one(from account in Account, where: account.id == ^id, lock: "FOR UPDATE")
  end

  defp lock_account(_id), do: nil

  defp lock_scope(%Scope{account_id: account_id} = scope) when is_integer(account_id) do
    account =
      Repo.one(
        from candidate in Account,
          where: candidate.id == ^account_id,
          lock: "FOR UPDATE"
      ) || Repo.rollback(:unauthorized)

    case Accounts.refresh_scope_for_account(account, scope) do
      {:ok, fresh_scope} -> fresh_scope
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_scope(_scope), do: Repo.rollback(:unauthorized)

  defp lock_repository(id) when is_integer(id) do
    Repo.one(from repository in Repository, where: repository.id == ^id, lock: "FOR UPDATE")
  end

  defp lock_repository(_id), do: nil

  defp lock_membership(id) when is_integer(id) do
    from(membership in RepositoryMembership,
      where: membership.id == ^id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp lock_membership(_id), do: nil

  defp prevent_self_verification(
         %Scope{account_id: account_id},
         %RepositoryMembership{account_id: account_id},
         "verified"
       ),
       do: {:error, :conflict_of_interest}

  defp prevent_self_verification(_scope, _membership, _status), do: :ok

  defp audit!(scope, action, subject, attrs) do
    case Audit.record(scope, action, subject, attrs) do
      {:ok, _event} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  defp notify_membership_authorization_change(
         {:ok,
          %RepositoryMembership{
            account_id: account_id,
            repository_id: repository_id
          }} = result
       ) do
    Accounts.broadcast_authorization_changed(account_id)
    _revalidation = Scans.revalidate_repository_authority(repository_id)
    result
  end

  defp notify_membership_authorization_change(result), do: result

  defp notify_repository_update({:ok, %Repository{} = repository} = result) do
    unless Repo.in_transaction?() do
      invalidate_registry_stats()
      broadcast_record_updated(repository)
    end

    result
  end

  defp notify_repository_update(result), do: result

  # Records are public by default; only a moderation quarantine narrows a
  # repository to its submitter, reviewers, and moderators.
  defp repository_visible?(%Repository{listing_status: status}, _scope)
       when status != "quarantined",
       do: true

  defp repository_visible?(%Repository{submitted_by_id: account_id}, %Scope{
         account_id: account_id
       }),
       do: true

  defp repository_visible?(repository, %Scope{} = scope) do
    Policy.moderator?(scope) or Policy.repository_reviewer?(scope, repository)
  end

  defp repository_visible?(_repository, _scope), do: false

  defp authorize_participation_mode(scope, attrs) do
    requested_mode = Map.get(attrs, :participation_mode) || Map.get(attrs, "participation_mode")

    if requested_mode == "curated" and not Policy.moderator?(scope) do
      {:error, :unauthorized}
    else
      :ok
    end
  end

  defp repository_hold_allows_mode(scope, repository, attrs) do
    requested_mode = Map.get(attrs, :participation_mode) || Map.get(attrs, "participation_mode")

    if Holds.repository_held?(repository.id) and requested_mode != "paused" and
         not Policy.moderator?(scope) do
      {:error, :unauthorized}
    else
      :ok
    end
  end

  defp repository_hold_allows_listing(scope, repository, requested_status) do
    if Holds.repository_held?(repository.id) and requested_status != "quarantined" and
         not Policy.moderator?(scope) do
      {:error, :unauthorized}
    else
      :ok
    end
  end
end
