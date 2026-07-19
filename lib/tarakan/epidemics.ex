defmodule Tarakan.Epidemics do
  @moduledoc """
  Cross-repository epidemic map with pre-aggregated rollups.

  Source of truth remains public canonical findings on listed repositories.
  `epidemic_patterns` / instances / memberships are async projections.
  """

  import Ecto.Query, warn: false

  alias Tarakan.Accounts.Scope

  alias Tarakan.Epidemics.{
    EnqueueRepoPatterns,
    Pattern,
    PatternInstance,
    PatternRepo,
    RefreshPattern
  }

  alias Tarakan.FindingMemory
  alias Tarakan.Policy
  alias Tarakan.Repo
  alias Tarakan.Repositories.Repository
  alias Tarakan.Scans.{CanonicalFinding, Finding, Scan}
  alias Tarakan.Work

  @default_min_repos 2
  @default_limit 40
  @max_limit 100
  @default_days 30
  @max_swarm_jobs 25
  @list_instances_max 300
  @page_max 100
  @max_inline_enqueue 200
  @windows [7, 30, 90, 365]

  # ---------------------------------------------------------------------------
  # Public reads
  # ---------------------------------------------------------------------------

  @doc """
  Lists active epidemics: patterns seen in at least `min_repos` listed repositories
  within the trailing window.
  """
  def list_epidemics(opts \\ []) do
    if read_from_rollup?() do
      list_epidemics_from_rollup(opts)
    else
      list_epidemics_legacy(opts)
    end
  end

  @doc "Loads one epidemic by pattern key, or nil."
  def get_epidemic(pattern_key) when is_binary(pattern_key) and pattern_key != "" do
    if read_from_rollup?() do
      case Repo.get(Pattern, pattern_key) do
        %Pattern{} = p -> pattern_to_show_map(p)
        nil -> get_epidemic_legacy(pattern_key)
      end
    else
      get_epidemic_legacy(pattern_key)
    end
  end

  def get_epidemic(_), do: nil

  @doc "Listed-repo instances of a pattern, newest first. Compat list; max 300."
  def list_instances(pattern_key, opts \\ [])

  def list_instances(pattern_key, opts) when is_binary(pattern_key) and pattern_key != "" do
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(@list_instances_max)
    fetch_instances(pattern_key, limit: limit, cursor: nil).entries
  end

  def list_instances(_, _), do: []

  @doc "Cursor page for UI ledger. Max 100 (default 50)."
  def list_instances_page(pattern_key, opts \\ [])

  def list_instances_page(pattern_key, opts) when is_binary(pattern_key) and pattern_key != "" do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(@page_max)
    fetch_instances(pattern_key, limit: limit, cursor: Keyword.get(opts, :cursor))
  end

  def list_instances_page(_, _), do: %{entries: [], next_cursor: nil}

  @doc "Per-repo memberships for contagion graph. Max 100 (default 64)."
  def list_pattern_repos_page(pattern_key, opts \\ [])

  def list_pattern_repos_page(pattern_key, opts)
      when is_binary(pattern_key) and pattern_key != "" do
    limit = opts |> Keyword.get(:limit, 64) |> max(1) |> min(@page_max)
    cursor = Keyword.get(opts, :cursor)

    query =
      from(m in PatternRepo,
        join: r in Repository,
        on: r.id == m.repository_id,
        where: m.pattern_key == ^pattern_key,
        order_by: [desc: m.last_seen_at, desc: m.repository_id],
        limit: ^(limit + 1),
        select: %{
          id: m.repository_id,
          repository_id: m.repository_id,
          host: r.host,
          owner: r.owner,
          name: r.name,
          status: m.primary_status,
          severity: m.severity,
          title: m.title,
          instance_count: m.instance_count,
          open_count: m.open_count,
          occurrence_public_id: m.sample_occurrence_public_id,
          updated_at: m.last_seen_at
        }
      )

    query =
      case cursor do
        {seen_at, repo_id} when not is_nil(seen_at) ->
          where(
            query,
            [m, _r],
            m.last_seen_at < ^seen_at or
              (m.last_seen_at == ^seen_at and m.repository_id < ^repo_id)
          )

        _ ->
          query
      end

    rows = Repo.all(query)
    {page, rest} = Enum.split(rows, limit)

    next_cursor =
      case rest do
        [%{updated_at: t, repository_id: id} | _] -> {t, id}
        _ -> nil
      end

    %{entries: page, next_cursor: next_cursor}
  end

  def list_pattern_repos_page(_, _), do: %{entries: [], next_cursor: nil}

  @doc """
  Opens budgeted check jobs for open epidemic instances that lack an active
  verify job. Moderator/admin only.
  """
  def swarm_check_jobs(%Scope{} = scope, pattern_key) when is_binary(pattern_key) do
    with :ok <- Policy.authorize(scope, :moderate) do
      instances =
        pattern_key
        |> list_instances(limit: 200)
        |> Enum.filter(&(&1.status == "open"))
        |> Enum.take(@max_swarm_jobs)

      results =
        Enum.map(instances, fn instance ->
          Work.open_epidemic_verification_job(scope, instance)
        end)

      opened =
        Enum.count(results, fn
          {:ok, task} when is_map(task) -> true
          _ -> false
        end)

      skipped =
        Enum.count(results, fn
          {:ok, reason} when reason in [:skipped_duplicate, :skipped_budget] -> true
          _ -> false
        end)

      failed = Enum.count(results, &match?({:error, _}, &1))

      {:ok, %{opened: opened, skipped: skipped, failed: failed, results: results}}
    end
  end

  def swarm_check_jobs(_scope, _pattern_key), do: {:error, :unauthorized}

  @doc "Pattern key helper exported for tests and UI."
  defdelegate pattern_key(title), to: FindingMemory

  # ---------------------------------------------------------------------------
  # Projection schedule (post-commit only)
  # ---------------------------------------------------------------------------

  @doc """
  Enqueue per-key refresh. Safe only after the outer transaction committed.
  """
  def schedule_refresh_after_commit(pattern_keys, opts \\ []) when is_list(pattern_keys) do
    # Prefer post-commit callers. When invoked inside Multi (e.g. listing
    # containment), Oban inserts join the transaction; sync_refresh recomputes
    # against the same connection's staged state — both are acceptable.
    reason = Keyword.get(opts, :reason, :assimilate) |> to_string()

    pattern_keys
    |> Enum.uniq()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.each(fn key -> enqueue_one(key, reason) end)

    :ok
  end

  def schedule_refresh_for_scan_after_commit(scan, opts \\ [])

  def schedule_refresh_for_scan_after_commit(%Scan{} = scan, opts) do
    keys = pattern_keys_for_scan(scan)
    schedule_refresh_after_commit(keys, opts)
  end

  def schedule_refresh_for_scan_after_commit(_, _), do: :ok

  def schedule_refresh_for_repository_after_commit(repository_id, opts \\ [])
      when is_integer(repository_id) do
    reason = Keyword.get(opts, :reason, :listing_change) |> to_string()
    keys = pattern_keys_for_repository(repository_id)
    {now, rest} = Enum.split(keys, @max_inline_enqueue)
    Enum.each(now, &enqueue_one(&1, reason))

    if rest != [] do
      %{
        "repository_id" => repository_id,
        "offset" => @max_inline_enqueue,
        "reason" => reason
      }
      |> EnqueueRepoPatterns.new()
      |> Oban.insert()
    end

    :ok
  end

  @doc false
  def pattern_keys_for_repository(repository_id) when is_integer(repository_id) do
    from_rollup =
      Repo.all(
        from m in PatternRepo,
          where: m.repository_id == ^repository_id,
          select: m.pattern_key,
          distinct: true
      )

    from_source =
      Repo.all(
        from c in CanonicalFinding,
          join: f in Finding,
          on: f.canonical_finding_id == c.id,
          join: s in Scan,
          on: s.id == f.scan_id,
          where:
            c.repository_id == ^repository_id and s.visibility == "public" and
              not is_nil(c.pattern_key) and c.pattern_key != "",
          select: c.pattern_key,
          distinct: true
      )

    (from_rollup ++ from_source)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  def pattern_keys_for_scan(%Scan{id: scan_id}) do
    Repo.all(
      from f in Finding,
        join: c in CanonicalFinding,
        on: c.id == f.canonical_finding_id,
        where: f.scan_id == ^scan_id and not is_nil(c.pattern_key) and c.pattern_key != "",
        select: c.pattern_key,
        distinct: true
    )
  end

  def pattern_keys_for_scan(_), do: []

  defp enqueue_one(pattern_key, reason) do
    conf = Application.get_env(:tarakan, :epidemics, [])

    cond do
      Keyword.get(conf, :sync_refresh, false) ->
        _ = refresh_pattern!(pattern_key)
        :ok

      Keyword.get(conf, :refresh_async, true) == false ->
        :ok

      true ->
        %{pattern_key: pattern_key, reason: reason}
        |> RefreshPattern.new()
        |> Oban.insert()
        |> case do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Recompute
  # ---------------------------------------------------------------------------

  @doc "Full recompute of one pattern from public listed sources."
  def refresh_pattern!(pattern_key) when is_binary(pattern_key) and pattern_key != "" do
    started = System.monotonic_time()
    rows = public_canonicals(pattern_key)

    if rows == [] do
      delete_pattern_projection(pattern_key)
    else
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        Repo.delete_all(from i in PatternInstance, where: i.pattern_key == ^pattern_key)

        Enum.each(rows, fn row ->
          %PatternInstance{}
          |> Ecto.Changeset.change(%{
            canonical_finding_id: row.canonical_finding_id,
            pattern_key: pattern_key,
            repository_id: row.repository_id,
            status: row.status,
            severity: row.severity,
            title: row.title || "Unknown pattern",
            file_path: row.file_path,
            sample_occurrence_public_id: row.sample_occurrence_public_id,
            inserted_at: row.inserted_at,
            updated_at: row.updated_at
          })
          |> Repo.insert!(
            on_conflict: {:replace_all_except, [:canonical_finding_id]},
            conflict_target: [:canonical_finding_id]
          )
        end)

        upsert_memberships_from_instances(pattern_key)
        upsert_pattern_from_instances(pattern_key, rows, now)
      end)
    end

    duration = System.monotonic_time() - started

    :telemetry.execute(
      [:tarakan, :epidemics, :refresh],
      %{duration: duration, instance_count: length(rows)},
      %{pattern_key: pattern_key}
    )

    :ok
  end

  def refresh_pattern!(_), do: :ok

  @doc "Recompute window columns from instance grain only (no CF join)."
  def recompute_windows!(pattern_key) when is_binary(pattern_key) and pattern_key != "" do
    instances =
      Repo.all(from i in PatternInstance, where: i.pattern_key == ^pattern_key)

    if instances == [] do
      delete_pattern_projection(pattern_key)
    else
      now = DateTime.utc_now()
      window_attrs = window_attrs_from_instances(instances, now)

      case Repo.get(Pattern, pattern_key) do
        %Pattern{} = p ->
          p
          |> Ecto.Changeset.change(Map.put(window_attrs, :refreshed_at, now))
          |> Repo.update!()

        nil ->
          # Pattern row missing but instances exist — full refresh
          refresh_pattern!(pattern_key)
      end
    end

    :ok
  end

  def recompute_windows!(_), do: :ok

  defp public_canonicals(pattern_key) do
    Repo.all(
      from c in CanonicalFinding,
        join: r in Repository,
        on: r.id == c.repository_id,
        join: f in Finding,
        on: f.canonical_finding_id == c.id,
        join: s in Scan,
        on: s.id == f.scan_id,
        where:
          c.pattern_key == ^pattern_key and r.listing_status == "listed" and
            s.visibility == "public" and not is_nil(c.pattern_key) and c.pattern_key != "",
        distinct: c.id,
        order_by: [asc: c.id, desc: s.inserted_at, desc: f.id],
        select: %{
          canonical_finding_id: c.id,
          repository_id: c.repository_id,
          status: c.status,
          severity: c.severity,
          title: c.title,
          file_path: c.file_path,
          sample_occurrence_public_id: f.public_id,
          inserted_at: c.inserted_at,
          updated_at: c.updated_at
        }
    )
  end

  defp upsert_memberships_from_instances(pattern_key) do
    instances =
      Repo.all(from i in PatternInstance, where: i.pattern_key == ^pattern_key)

    by_repo = Enum.group_by(instances, & &1.repository_id)
    now = DateTime.utc_now()
    active_ids = Map.keys(by_repo)

    Enum.each(by_repo, fn {repo_id, rows} ->
      attrs = membership_attrs(pattern_key, repo_id, rows, now)

      %PatternRepo{}
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert!(
        on_conflict: {:replace_all_except, [:pattern_key, :repository_id, :inserted_at]},
        conflict_target: [:pattern_key, :repository_id]
      )
    end)

    if active_ids == [] do
      Repo.delete_all(from m in PatternRepo, where: m.pattern_key == ^pattern_key)
    else
      Repo.delete_all(
        from m in PatternRepo,
          where: m.pattern_key == ^pattern_key and m.repository_id not in ^active_ids
      )
    end
  end

  defp membership_attrs(pattern_key, repo_id, rows, now) do
    primary =
      cond do
        Enum.any?(rows, &(&1.status == "open")) -> "open"
        Enum.any?(rows, &(&1.status == "disputed")) -> "disputed"
        Enum.any?(rows, &(&1.status == "verified")) -> "verified"
        true -> "fixed"
      end

    rep =
      rows
      |> Enum.sort_by(fn r ->
        {status_rank(r.status), -DateTime.to_unix(r.updated_at, :microsecond)}
      end)
      |> List.first()

    %{
      pattern_key: pattern_key,
      repository_id: repo_id,
      instance_count: length(rows),
      open_count: Enum.count(rows, &(&1.status == "open")),
      verified_count: Enum.count(rows, &(&1.status == "verified")),
      fixed_count: Enum.count(rows, &(&1.status == "fixed")),
      disputed_count: Enum.count(rows, &(&1.status == "disputed")),
      primary_status: primary,
      severity: rep && rep.severity,
      title: (rep && rep.title) || "Unknown pattern",
      sample_occurrence_public_id: rep && rep.sample_occurrence_public_id,
      first_seen_at: rows |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime),
      last_seen_at: rows |> Enum.map(& &1.updated_at) |> Enum.max(DateTime),
      inserted_at: now,
      updated_at: now
    }
  end

  defp upsert_pattern_from_instances(pattern_key, rows, now) do
    window_attrs = window_attrs_from_instances(rows, now)
    rep = representative_row(rows)

    all_time = %{
      pattern_key: pattern_key,
      title: (rep && rep.title) || "Unknown pattern",
      severity: rep && rep.severity,
      sample_file_path: rep && rep.file_path,
      sample_occurrence_public_id: rep && rep.sample_occurrence_public_id,
      repo_count: rows |> Enum.map(& &1.repository_id) |> Enum.uniq() |> length(),
      instance_count: length(rows),
      open_count: Enum.count(rows, &(&1.status == "open")),
      verified_count: Enum.count(rows, &(&1.status == "verified")),
      fixed_count: Enum.count(rows, &(&1.status == "fixed")),
      disputed_count: Enum.count(rows, &(&1.status == "disputed")),
      first_seen_at: rows |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime),
      last_seen_at: rows |> Enum.map(& &1.updated_at) |> Enum.max(DateTime),
      refreshed_at: now,
      inserted_at: now,
      updated_at: now
    }

    attrs = Map.merge(all_time, window_attrs)

    %Pattern{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:pattern_key, :inserted_at]},
      conflict_target: [:pattern_key]
    )
  end

  defp window_attrs_from_instances(rows, now) do
    Enum.reduce(@windows, %{}, fn days, acc ->
      since = DateTime.add(now, -days, :day)
      in_window = Enum.filter(rows, &(DateTime.compare(&1.updated_at, since) != :lt))

      last_seen =
        case in_window do
          [] -> nil
          list -> list |> Enum.map(& &1.updated_at) |> Enum.max(DateTime)
        end

      counts = %{
        repo: in_window |> Enum.map(& &1.repository_id) |> Enum.uniq() |> length(),
        instance: length(in_window),
        open: Enum.count(in_window, &(&1.status == "open")),
        verified: Enum.count(in_window, &(&1.status == "verified")),
        fixed: Enum.count(in_window, &(&1.status == "fixed")),
        disputed: Enum.count(in_window, &(&1.status == "disputed")),
        last_seen: last_seen
      }

      Map.merge(acc, window_count_map(days, counts))
    end)
  end

  defp window_count_map(7, c) do
    %{
      repo_count_7d: c.repo,
      instance_count_7d: c.instance,
      open_count_7d: c.open,
      verified_count_7d: c.verified,
      fixed_count_7d: c.fixed,
      disputed_count_7d: c.disputed,
      last_seen_at_7d: c.last_seen
    }
  end

  defp window_count_map(30, c) do
    %{
      repo_count_30d: c.repo,
      instance_count_30d: c.instance,
      open_count_30d: c.open,
      verified_count_30d: c.verified,
      fixed_count_30d: c.fixed,
      disputed_count_30d: c.disputed,
      last_seen_at_30d: c.last_seen
    }
  end

  defp window_count_map(90, c) do
    %{
      repo_count_90d: c.repo,
      instance_count_90d: c.instance,
      open_count_90d: c.open,
      verified_count_90d: c.verified,
      fixed_count_90d: c.fixed,
      disputed_count_90d: c.disputed,
      last_seen_at_90d: c.last_seen
    }
  end

  defp window_count_map(365, c) do
    %{
      repo_count_365d: c.repo,
      instance_count_365d: c.instance,
      open_count_365d: c.open,
      verified_count_365d: c.verified,
      fixed_count_365d: c.fixed,
      disputed_count_365d: c.disputed,
      last_seen_at_365d: c.last_seen
    }
  end

  defp representative_row(rows) do
    rows
    |> Enum.sort_by(fn r ->
      {status_rank(r.status), -DateTime.to_unix(r.updated_at, :microsecond)}
    end)
    |> List.first()
  end

  defp status_rank("open"), do: 0
  defp status_rank("disputed"), do: 1
  defp status_rank("verified"), do: 2
  defp status_rank(_), do: 3

  defp delete_pattern_projection(pattern_key) do
    Repo.delete_all(from i in PatternInstance, where: i.pattern_key == ^pattern_key)
    Repo.delete_all(from m in PatternRepo, where: m.pattern_key == ^pattern_key)
    Repo.delete_all(from p in Pattern, where: p.pattern_key == ^pattern_key)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Rollup reads
  # ---------------------------------------------------------------------------

  defp list_epidemics_from_rollup(opts) do
    min_repos = opts |> Keyword.get(:min_repos, @default_min_repos) |> max(2) |> min(50)
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)
    days = opts |> Keyword.get(:days, @default_days) |> max(1) |> min(365)
    status = Keyword.get(opts, :status)
    window = window_bucket(days)
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    case status do
      s when s in [nil, "all"] ->
        {rc, ls} = window_fields(window)

        from(p in Pattern,
          where: field(p, ^rc) >= ^min_repos,
          where: not is_nil(field(p, ^ls)) and field(p, ^ls) >= ^since,
          order_by: [desc: field(p, ^rc), desc: field(p, ^ls)],
          limit: ^limit
        )
        |> Repo.all()
        |> Enum.map(&to_epidemic_map(&1, window))

      s when s in ~w(open verified disputed fixed) ->
        list_epidemics_status_window(s, since, min_repos, limit)

      _ ->
        list_epidemics_from_rollup(Keyword.put(opts, :status, nil))
    end
  end

  defp list_epidemics_status_window(status, since, min_repos, limit) do
    rows =
      Repo.all(
        from i in PatternInstance,
          where: i.status == ^status and i.updated_at >= ^since,
          group_by: i.pattern_key,
          having: count(i.repository_id, :distinct) >= ^min_repos,
          order_by: [desc: count(i.repository_id, :distinct), desc: max(i.updated_at)],
          limit: ^limit,
          select: %{
            pattern_key: i.pattern_key,
            repo_count: count(i.repository_id, :distinct),
            instance_count: count(i.canonical_finding_id),
            last_seen_at: max(i.updated_at),
            first_seen_at: min(i.inserted_at),
            open_count: fragment("count(*) FILTER (WHERE ? = 'open')", i.status),
            verified_count: fragment("count(*) FILTER (WHERE ? = 'verified')", i.status),
            fixed_count: fragment("count(*) FILTER (WHERE ? = 'fixed')", i.status),
            disputed_count: fragment("count(*) FILTER (WHERE ? = 'disputed')", i.status)
          }
      )

    # Status filter means all instances match status — fill other counts as 0 except matched
    keys = Enum.map(rows, & &1.pattern_key)
    titles = titles_from_patterns(keys)

    Enum.map(rows, fn row ->
      title_row = Map.get(titles, row.pattern_key, %{})

      counts =
        case status do
          "open" ->
            %{
              open_count: row.instance_count,
              verified_count: 0,
              fixed_count: 0,
              disputed_count: 0
            }

          "verified" ->
            %{
              open_count: 0,
              verified_count: row.instance_count,
              fixed_count: 0,
              disputed_count: 0
            }

          "fixed" ->
            %{
              open_count: 0,
              verified_count: 0,
              fixed_count: row.instance_count,
              disputed_count: 0
            }

          "disputed" ->
            %{
              open_count: 0,
              verified_count: 0,
              fixed_count: 0,
              disputed_count: row.instance_count
            }
        end

      Map.merge(
        %{
          pattern_key: row.pattern_key,
          repo_count: row.repo_count,
          instance_count: row.instance_count,
          last_seen_at: row.last_seen_at,
          first_seen_at: row.first_seen_at,
          title: title_row[:title] || "Unknown pattern",
          severity: title_row[:severity],
          sample_file_path: title_row[:sample_file_path],
          sample_occurrence_public_id: title_row[:sample_occurrence_public_id]
        },
        counts
      )
    end)
  end

  defp titles_from_patterns(keys) when keys == [], do: %{}

  defp titles_from_patterns(keys) do
    Repo.all(from p in Pattern, where: p.pattern_key in ^keys)
    |> Map.new(fn p ->
      {p.pattern_key,
       %{
         title: p.title,
         severity: p.severity,
         sample_file_path: p.sample_file_path,
         sample_occurrence_public_id: p.sample_occurrence_public_id
       }}
    end)
  end

  defp to_epidemic_map(%Pattern{} = p, window) do
    {rc, ic, oc, vc, fc, dc, ls} = window_count_fields(window)

    %{
      pattern_key: p.pattern_key,
      title: p.title,
      severity: p.severity,
      sample_file_path: p.sample_file_path,
      sample_occurrence_public_id: p.sample_occurrence_public_id,
      repo_count: Map.fetch!(p, rc),
      instance_count: Map.fetch!(p, ic),
      open_count: Map.fetch!(p, oc),
      verified_count: Map.fetch!(p, vc),
      fixed_count: Map.fetch!(p, fc),
      disputed_count: Map.fetch!(p, dc),
      last_seen_at: Map.fetch!(p, ls),
      first_seen_at: p.first_seen_at
    }
  end

  defp pattern_to_show_map(%Pattern{} = p) do
    %{
      pattern_key: p.pattern_key,
      title: p.title,
      severity: p.severity,
      sample_file_path: p.sample_file_path,
      sample_occurrence_public_id: p.sample_occurrence_public_id,
      repo_count: p.repo_count,
      instance_count: p.instance_count,
      open_count: p.open_count,
      verified_count: p.verified_count,
      fixed_count: p.fixed_count,
      disputed_count: p.disputed_count,
      last_seen_at: p.last_seen_at,
      first_seen_at: p.first_seen_at
    }
  end

  defp window_bucket(days) when days <= 7, do: 7
  defp window_bucket(days) when days <= 30, do: 30
  defp window_bucket(days) when days <= 90, do: 90
  defp window_bucket(_), do: 365

  defp window_fields(7), do: {:repo_count_7d, :last_seen_at_7d}
  defp window_fields(30), do: {:repo_count_30d, :last_seen_at_30d}
  defp window_fields(90), do: {:repo_count_90d, :last_seen_at_90d}
  defp window_fields(365), do: {:repo_count_365d, :last_seen_at_365d}

  defp window_count_fields(7) do
    {:repo_count_7d, :instance_count_7d, :open_count_7d, :verified_count_7d, :fixed_count_7d,
     :disputed_count_7d, :last_seen_at_7d}
  end

  defp window_count_fields(30) do
    {:repo_count_30d, :instance_count_30d, :open_count_30d, :verified_count_30d, :fixed_count_30d,
     :disputed_count_30d, :last_seen_at_30d}
  end

  defp window_count_fields(90) do
    {:repo_count_90d, :instance_count_90d, :open_count_90d, :verified_count_90d, :fixed_count_90d,
     :disputed_count_90d, :last_seen_at_90d}
  end

  defp window_count_fields(365) do
    {:repo_count_365d, :instance_count_365d, :open_count_365d, :verified_count_365d,
     :fixed_count_365d, :disputed_count_365d, :last_seen_at_365d}
  end

  defp read_from_rollup? do
    conf = Application.get_env(:tarakan, :epidemics, [])
    Keyword.get(conf, :read_from_rollup, false) == true
  end

  # ---------------------------------------------------------------------------
  # Instances fetch
  # ---------------------------------------------------------------------------

  defp fetch_instances(pattern_key, opts) do
    limit = Keyword.fetch!(opts, :limit)
    cursor = Keyword.get(opts, :cursor)

    # Prefer rollup instance grain joined to repo when available; else legacy join.
    if Repo.exists?(from i in PatternInstance, where: i.pattern_key == ^pattern_key, limit: 1) do
      fetch_instances_from_rollup(pattern_key, limit, cursor)
    else
      fetch_instances_legacy(pattern_key, limit, cursor)
    end
  end

  defp fetch_instances_from_rollup(pattern_key, limit, cursor) do
    query =
      from(i in PatternInstance,
        join: r in Repository,
        on: r.id == i.repository_id,
        where: i.pattern_key == ^pattern_key,
        order_by: [desc: i.updated_at, desc: i.canonical_finding_id],
        limit: ^(limit + 1),
        select: %{
          id: i.canonical_finding_id,
          public_id: nil,
          occurrence_public_id: i.sample_occurrence_public_id,
          status: i.status,
          severity: i.severity,
          title: i.title,
          file_path: i.file_path,
          detections_count: 0,
          confirmations_count: 0,
          host: r.host,
          owner: r.owner,
          name: r.name,
          repository_id: r.id,
          commit_sha: nil,
          scan_id: nil,
          updated_at: i.updated_at
        }
      )

    query =
      case cursor do
        {updated_at, id} when not is_nil(updated_at) ->
          where(
            query,
            [i, _r],
            i.updated_at < ^updated_at or
              (i.updated_at == ^updated_at and i.canonical_finding_id < ^id)
          )

        _ ->
          query
      end

    rows = Repo.all(query)
    # Fill public_id / detections from canonical when present
    rows = enrich_instance_rows(rows)
    {page, rest} = Enum.split(rows, limit)

    next_cursor =
      case rest do
        [%{updated_at: t, id: id} | _] -> {t, id}
        _ -> nil
      end

    %{entries: page, next_cursor: next_cursor}
  end

  defp enrich_instance_rows([]), do: []

  defp enrich_instance_rows(rows) do
    ids = Enum.map(rows, & &1.id)

    canon =
      Repo.all(from c in CanonicalFinding, where: c.id in ^ids)
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn row ->
      case Map.get(canon, row.id) do
        %CanonicalFinding{} = c ->
          %{
            row
            | public_id: c.public_id,
              detections_count: c.detections_count,
              confirmations_count: c.confirmations_count
          }

        _ ->
          row
      end
    end)
  end

  defp fetch_instances_legacy(pattern_key, limit, cursor) do
    query =
      CanonicalFinding
      |> join(:inner, [canonical], repository in assoc(canonical, :repository))
      |> join(:inner, [canonical], occurrence in Finding,
        on: occurrence.canonical_finding_id == canonical.id
      )
      |> join(:inner, [_canonical, _repository, occurrence], scan in Scan,
        on: scan.id == occurrence.scan_id
      )
      |> where(
        [canonical, repository, _occurrence, scan],
        canonical.pattern_key == ^pattern_key and repository.listing_status == "listed" and
          scan.visibility == "public"
      )
      |> distinct([canonical], canonical.id)
      |> order_by([canonical, _repository, occurrence, scan],
        desc: canonical.updated_at,
        desc: canonical.id,
        desc: scan.inserted_at,
        desc: occurrence.id
      )
      |> limit(^(limit + 1))
      |> select([canonical, repository, occurrence, scan], %{
        id: canonical.id,
        public_id: canonical.public_id,
        occurrence_public_id: occurrence.public_id,
        status: canonical.status,
        severity: canonical.severity,
        title: canonical.title,
        file_path: canonical.file_path,
        detections_count: canonical.detections_count,
        confirmations_count: canonical.confirmations_count,
        host: repository.host,
        owner: repository.owner,
        name: repository.name,
        repository_id: repository.id,
        commit_sha: scan.commit_sha,
        scan_id: scan.id,
        updated_at: canonical.updated_at
      })

    query =
      case cursor do
        {updated_at, id} when not is_nil(updated_at) ->
          where(
            query,
            [canonical, _, _, _],
            canonical.updated_at < ^updated_at or
              (canonical.updated_at == ^updated_at and canonical.id < ^id)
          )

        _ ->
          query
      end

    rows = Repo.all(query)
    {page, rest} = Enum.split(rows, limit)

    next_cursor =
      case rest do
        [%{updated_at: t, id: id} | _] -> {t, id}
        _ -> nil
      end

    %{entries: page, next_cursor: next_cursor}
  end

  # ---------------------------------------------------------------------------
  # Legacy online aggregation (fallback)
  # ---------------------------------------------------------------------------

  def list_epidemics_legacy(opts \\ []) do
    min_repos = opts |> Keyword.get(:min_repos, @default_min_repos) |> max(2) |> min(50)
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)
    days = opts |> Keyword.get(:days, @default_days) |> max(1) |> min(365)
    since = DateTime.add(DateTime.utc_now(), -days, :day)
    status = Keyword.get(opts, :status)

    base =
      CanonicalFinding
      |> join(:inner, [canonical], repository in assoc(canonical, :repository))
      |> join(:inner, [canonical], occurrence in Finding,
        on: occurrence.canonical_finding_id == canonical.id
      )
      |> join(:inner, [_canonical, _repository, occurrence], scan in Scan,
        on: scan.id == occurrence.scan_id
      )
      |> where(
        [canonical, repository, _occurrence, scan],
        repository.listing_status == "listed" and scan.visibility == "public" and
          not is_nil(canonical.pattern_key) and canonical.pattern_key != "" and
          canonical.updated_at >= ^since
      )
      |> maybe_status(status)

    aggregates =
      base
      |> group_by([canonical], canonical.pattern_key)
      |> having([canonical], count(canonical.repository_id, :distinct) >= ^min_repos)
      |> order_by([canonical], desc: count(canonical.repository_id, :distinct))
      |> order_by([canonical], desc: max(canonical.updated_at))
      |> limit(^limit)
      |> select([canonical], %{
        pattern_key: canonical.pattern_key,
        repo_count: count(canonical.repository_id, :distinct),
        instance_count: count(canonical.id, :distinct),
        open_count:
          count(canonical.id, :distinct)
          |> filter(canonical.status == "open"),
        verified_count:
          count(canonical.id, :distinct)
          |> filter(canonical.status == "verified"),
        fixed_count:
          count(canonical.id, :distinct)
          |> filter(canonical.status == "fixed"),
        disputed_count:
          count(canonical.id, :distinct)
          |> filter(canonical.status == "disputed"),
        last_seen_at: max(canonical.updated_at),
        first_seen_at: min(canonical.inserted_at)
      })
      |> Repo.all()

    representatives = representative_titles(Enum.map(aggregates, & &1.pattern_key))

    Enum.map(aggregates, fn row ->
      rep = Map.get(representatives, row.pattern_key, %{})

      Map.merge(row, %{
        title: rep[:title] || "Unknown pattern",
        severity: rep[:severity],
        sample_file_path: rep[:file_path],
        sample_occurrence_public_id: rep[:occurrence_public_id]
      })
    end)
  end

  defp get_epidemic_legacy(pattern_key) do
    case epidemic_stats(pattern_key) do
      %{repo_count: n} = stats when is_integer(n) and n >= 1 ->
        rep = representative_titles([pattern_key]) |> Map.get(pattern_key, %{})

        Map.merge(stats, %{
          title: rep[:title] || "Unknown pattern",
          severity: rep[:severity],
          sample_file_path: rep[:file_path],
          sample_occurrence_public_id: rep[:occurrence_public_id]
        })

      _ ->
        nil
    end
  end

  defp maybe_status(query, nil), do: query
  defp maybe_status(query, "all"), do: query

  defp maybe_status(query, status) when status in ~w(open verified disputed fixed) do
    where(query, [canonical], canonical.status == ^status)
  end

  defp maybe_status(query, _), do: query

  defp epidemic_stats(pattern_key) do
    CanonicalFinding
    |> join(:inner, [canonical], repository in assoc(canonical, :repository))
    |> join(:inner, [canonical], occurrence in Finding,
      on: occurrence.canonical_finding_id == canonical.id
    )
    |> join(:inner, [_canonical, _repository, occurrence], scan in Scan,
      on: scan.id == occurrence.scan_id
    )
    |> where(
      [canonical, repository, _occurrence, scan],
      canonical.pattern_key == ^pattern_key and repository.listing_status == "listed" and
        scan.visibility == "public"
    )
    |> select([canonical], %{
      pattern_key: ^pattern_key,
      repo_count: count(canonical.repository_id, :distinct),
      instance_count: count(canonical.id, :distinct),
      open_count: count(canonical.id, :distinct) |> filter(canonical.status == "open"),
      verified_count: count(canonical.id, :distinct) |> filter(canonical.status == "verified"),
      fixed_count: count(canonical.id, :distinct) |> filter(canonical.status == "fixed"),
      disputed_count: count(canonical.id, :distinct) |> filter(canonical.status == "disputed"),
      last_seen_at: max(canonical.updated_at),
      first_seen_at: min(canonical.inserted_at)
    })
    |> Repo.one()
  end

  defp representative_titles([]), do: %{}

  defp representative_titles(pattern_keys) do
    CanonicalFinding
    |> where([canonical], canonical.pattern_key in ^pattern_keys)
    |> order_by(
      [canonical],
      asc: canonical.pattern_key,
      asc:
        fragment(
          "CASE ? WHEN 'open' THEN 0 WHEN 'disputed' THEN 1 WHEN 'verified' THEN 2 ELSE 3 END",
          canonical.status
        ),
      desc: canonical.updated_at,
      desc: canonical.id
    )
    |> distinct([canonical], canonical.pattern_key)
    |> join(:left, [canonical], occurrence in Finding,
      on: occurrence.canonical_finding_id == canonical.id
    )
    |> order_by([_canonical, occurrence], desc: occurrence.id)
    |> select([canonical, occurrence], {canonical.pattern_key, canonical, occurrence})
    |> Repo.all()
    |> Map.new(fn {key, canonical, occurrence} ->
      {key,
       %{
         title: canonical.title,
         severity: canonical.severity,
         file_path: canonical.file_path,
         occurrence_public_id: occurrence && occurrence.public_id
       }}
    end)
  end
end
