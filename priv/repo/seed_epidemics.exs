# Demo contagion data: multi-repo patterns for the epidemic map.
#
#     mix run priv/repo/seed_epidemics.exs
#
# Idempotent enough for demo: uses stable run_ids; re-running may hit unique
# constraints on run_id and skip duplicates. Prefer a fresh DB or delete
# epi-seed-* scans first if you need a clean reseed.

import Ecto.Query

alias Tarakan.Accounts.Account
alias Tarakan.Epidemics
alias Tarakan.Repo
alias Tarakan.Repositories.Repository
alias Tarakan.Scans

account =
  Repo.get_by(Account, email: "mod@example.com") ||
    Repo.one(from a in Account, where: a.platform_role in ["moderator", "admin"], limit: 1) ||
    Repo.one!(from a in Account, where: a.state == "active", limit: 1)

repos =
  from(r in Repository,
    where: r.listing_status == "listed",
    order_by: r.id
  )
  |> Repo.all()
  |> Enum.reject(fn r -> String.starts_with?(r.owner, "ghost-") end)

if repos == [] do
  Mix.shell().error("No listed repositories to seed epidemics into.")
  System.halt(1)
end

# {title, severity, status cycle per instance} — length of status list = repo fan-out
patterns = [
  {"SQL injection via string concatenation", "critical", ~w(open open verified open open)},
  {"Hardcoded credentials in config loader", "high", ~w(open fixed open verified open)},
  {"Command injection through shell interpolation", "critical", ~w(open open open open verified)},
  {"Path traversal in archive extract", "high", ~w(open open fixed open)},
  {"SSRF via user-controlled URL fetch", "high", ~w(open verified open open open)},
  {"JWT accepts alg=none", "critical", ~w(open open disputed open)},
  {"Missing authorization on admin API route", "critical", ~w(open open open verified open open)},
  {"Insecure deserialization of user input", "high", ~w(open fixed open open)},
  {"Open redirect after login", "medium", ~w(open open verified fixed open)},
  {"Prototype pollution in deep merge", "high", ~w(open open open open)},
  {"Debug endpoint left enabled", "medium", ~w(open fixed open open open)},
  {"Weak random token generation", "medium", ~w(open open verified open)},
  {"CORS reflects arbitrary Origin", "medium", ~w(open open open open open)},
  {"Timing-unsafe secret comparison", "high", ~w(open verified open open)},
  {"Unsanitized HTML rendered as markup", "high", ~w(open open open fixed verified open open)},
  {"XML external entity in parser", "high", ~w(open open verified)},
  {"LDAP injection in directory search", "high", ~w(open open open fixed)},
  {"Mass assignment on privileged fields", "medium", ~w(open verified open open open)},
  {"Broken access control on object ID", "critical", ~w(open open open open verified open)},
  {"Insecure direct object reference", "high", ~w(open open fixed open open)}
]

sha = fn i, repo_id, title ->
  :crypto.hash(:sha256, "seed-epi-v2-#{repo_id}-#{i}-#{title}")
  |> Base.encode16(case: :lower)
  |> String.slice(0, 40)
end

{ok_count, skip_count, err_count} =
  Enum.reduce(patterns, {0, 0, 0}, fn {title, severity, status_cycle}, {ok, skip, err} ->
    n = length(status_cycle)
    # Deterministic rotation so re-runs hit the same repos
    offset = :erlang.phash2(title, length(repos))

    selected =
      for i <- 0..(n - 1) do
        Enum.at(repos, rem(offset + i, length(repos)))
      end

    Enum.reduce(Enum.with_index(selected), {ok, skip, err}, fn {repo, i}, {ok, skip, err} ->
      status = Enum.at(status_cycle, i)
      path = "lib/seed/epidemic_#{:erlang.phash2(title, 10_000)}/mod_#{i}.ex"
      run_id = "epi-seed-v2-#{:erlang.phash2({title, repo.id, i}, 1_000_000_000)}"

      findings_json =
        Jason.encode!(%{
          "tarakan_scan_format" => 1,
          "findings" => [
            %{
              "file" => path,
              "line_start" => 10 + i * 3,
              "line_end" => 14 + i * 3,
              "severity" => severity,
              "title" => title,
              "description" =>
                "Demo epidemic seed: #{title} observed in #{repo.owner}/#{repo.name}."
            }
          ]
        })

      attrs = %{
        "repository_id" => repo.id,
        "submitted_by_id" => account.id,
        "commit_sha" => sha.(i, repo.id, title),
        "model" => "seed-agent",
        "prompt_version" => "epidemic-demo/v2",
        "run_id" => run_id,
        "provenance" => "agent",
        "review_kind" => "code_review",
        "findings_json" => findings_json,
        "visibility" => "public"
      }

      case Scans.stage_review_insert(attrs) do
        {:ok, scan} ->
          scan = Repo.preload(scan, findings: :canonical_finding)

          Enum.each(scan.findings, fn f ->
            if f.canonical_finding do
              f.canonical_finding
              |> Ecto.Changeset.change(%{status: status})
              |> Repo.update!()
            end
          end)

          Scans.recalculate_repository_metrics(repo.id)
          {ok + 1, skip, err}

        {:error, %Ecto.Changeset{} = cs} ->
          if Keyword.has_key?(cs.errors, :run_id) do
            {ok, skip + 1, err}
          else
            Mix.shell().error("FAIL #{title} @ #{repo.owner}/#{repo.name}: #{inspect(cs.errors)}")
            {ok, skip, err + 1}
          end

        {:error, reason} ->
          Mix.shell().error("FAIL #{title} @ #{repo.owner}/#{repo.name}: #{inspect(reason)}")
          {ok, skip, err + 1}
      end
    end)
  end)

# Project rollups so atlas reads (read_from_rollup) see seeded data immediately.
Mix.shell().info("Refreshing epidemic rollups…")
Tarakan.Epidemics.Backfill.run_sync!()

eps = Epidemics.list_epidemics(min_repos: 2, days: 365, limit: 50)

Mix.shell().info(
  "Epidemic seed: #{ok_count} inserted, #{skip_count} skipped, #{err_count} failed. " <>
    "#{length(eps)} multi-repo patterns visible."
)

Enum.each(eps, fn e ->
  Mix.shell().info(
    "  #{e.repo_count} repos · open=#{e.open_count} ver=#{e.verified_count} fix=#{e.fixed_count} · #{e.title}"
  )
end)
