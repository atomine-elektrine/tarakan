defmodule TarakanWeb.API.WorkControllerTest do
  use TarakanWeb.ConnCase, async: true

  alias Tarakan.Accounts
  alias Tarakan.Accounts.ApiCredentials
  alias Tarakan.Repositories.Repository
  alias Tarakan.Repo
  alias Tarakan.Work

  setup %{conn: conn} do
    creator = github_account_fixture()
    repository = listed_github_repository_fixture(creator)
    worker = account_fixture()
    worker_token = client_token(worker)
    creator_token = client_token(creator)

    %{
      conn: conn,
      creator: creator,
      creator_token: creator_token,
      repository: repository,
      worker: worker,
      worker_token: worker_token
    }
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp client_token(account) do
    {:ok, token, _credential} =
      ApiCredentials.create(account, %{
        name: "work controller test",
        scopes: ["tasks:read", "tasks:claim", "contributions:write"]
      })

    token
  end

  test "all work queue endpoints require an API token", %{conn: conn} do
    conn = get(conn, ~p"/api/github.com/openai/codex/jobs")

    assert json_response(conn, 401)["error"] =~ "API token"
  end

  test "lists the global open jobs queue", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker_token: token
  } do
    task = review_task_fixture(repository, creator)

    conn = conn |> authed(token) |> get(~p"/api/jobs")

    assert %{"jobs" => jobs} = json_response(conn, 200)
    assert Enum.any?(jobs, &(&1["id"] == task.id))
    match = Enum.find(jobs, &(&1["id"] == task.id))
    assert match["status"] == "open"
    assert match["repository"]["owner"] == repository.owner
    assert match["repository"]["name"] == repository.name
    assert match["repository"]["primary_language"] == repository.primary_language
    assert match["repository"]["stars_count"] == repository.stars_count
  end

  test "global jobs queue filters by language and min stars", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker_token: token
  } do
    task = review_task_fixture(repository, creator)

    # Fixture repo is Rust with 42000 stars (GitHub stub).
    conn =
      conn
      |> authed(token)
      |> get(~p"/api/jobs", %{"language" => "Rust", "min_stars" => "1000"})

    assert %{"jobs" => jobs} = json_response(conn, 200)
    assert Enum.any?(jobs, &(&1["id"] == task.id))

    conn =
      build_conn()
      |> authed(token)
      |> get(~p"/api/jobs", %{"language" => "Elixir"})

    assert %{"jobs" => jobs} = json_response(conn, 200)
    refute Enum.any?(jobs, &(&1["id"] == task.id))

    conn =
      build_conn()
      |> authed(token)
      |> get(~p"/api/jobs", %{"min_stars" => "999999"})

    assert %{"jobs" => jobs} = json_response(conn, 200)
    refute Enum.any?(jobs, &(&1["id"] == task.id))
  end

  test "global jobs queue includes the caller's active claims", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker: worker,
    worker_token: token
  } do
    task =
      review_task_fixture(repository, creator, %{"kind" => "code_review", "capability" => "agent"})

    {:ok, claimed} = Work.claim_task(task, worker)

    assert claimed.status == "claimed"

    conn = conn |> authed(token) |> get(~p"/api/jobs")
    assert %{"jobs" => jobs} = json_response(conn, 200)
    match = Enum.find(jobs, &(&1["id"] == claimed.id))
    assert match
    assert match["status"] == "claimed"
    assert match["lease"]["active"] == true
  end

  test "lists a repository's tasks with client-ready relationships", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker_token: token
  } do
    task = review_task_fixture(repository, creator)

    conn = conn |> authed(token) |> get(~p"/api/github.com/openai/codex/jobs")

    assert %{"jobs" => [response]} = json_response(conn, 200)
    assert response["id"] == task.id
    assert response["kind"] == "threat_model"
    assert response["capability"] == "human"
    assert response["status"] == "open"
    assert response["visibility"] == "public"
    assert response["commit_sha"] == task.commit_sha
    assert response["commit_committed_at"] == "2026-07-01T12:00:00.000000Z"

    assert response["repository"]["canonical_url"] == "https://github.com/openai/codex"
    assert response["repository"]["host"] == "github.com"
    assert response["repository"]["id"] == repository.id
    assert response["repository"]["name"] == "codex"
    assert response["repository"]["owner"] == "openai"
    assert response["repository"]["participation_mode"] == repository.participation_mode
    assert response["repository"]["record_url"] =~ "/github.com/openai/codex"

    assert response["creator"]["id"] == creator.id
    assert response["creator"]["handle"] == creator.handle
    assert response["creator"] |> Map.keys() |> Enum.sort() == ["handle", "id"]
    assert response["claimant"] == nil
    assert response["lease"] == nil
    assert response["contribution"] == nil
    assert response["job_url"] =~ "/jobs/#{task.id}"
  end

  test "returns an empty list and 404s an unregistered repository", %{
    conn: conn,
    worker_token: token
  } do
    conn1 = conn |> authed(token) |> get(~p"/api/github.com/openai/codex/jobs")
    assert json_response(conn1, 200) == %{"jobs" => []}

    conn2 =
      conn
      |> recycle()
      |> authed(token)
      |> get(~p"/api/github.com/unknown/repository/jobs")

    assert json_response(conn2, 404)["error"] =~ "not registered"
  end

  test "does not disclose a quarantined repository to an unrelated credential", %{
    conn: conn,
    repository: repository,
    worker_token: token
  } do
    _contained =
      repository
      |> Repository.listing_changeset(%{listing_status: "quarantined"})
      |> Repo.update!()

    conn = conn |> authed(token) |> get(~p"/api/github.com/openai/codex/jobs")

    assert json_response(conn, 404)["error"] =~ "not registered"
  end

  test "shows a task and returns 404 for missing or malformed ids", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker_token: token
  } do
    task = review_task_fixture(repository, creator)

    conn1 = conn |> authed(token) |> get(~p"/api/jobs/#{task.id}")
    assert json_response(conn1, 200)["id"] == task.id

    conn2 = conn |> recycle() |> authed(token) |> get("/api/jobs/not-an-id")
    assert json_response(conn2, 404)["error"] == "job not found"

    conn3 = conn |> recycle() |> authed(token) |> get("/api/jobs/999999999")
    assert json_response(conn3, 404)["error"] == "job not found"
  end

  test "claims a task and exposes the active lease", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker: worker,
    worker_token: token
  } do
    task = review_task_fixture(repository, creator)

    conn = conn |> authed(token) |> post(~p"/api/jobs/#{task.id}/claim")

    response = json_response(conn, 200)
    assert response["status"] == "claimed"
    assert response["claimant"]["id"] == worker.id
    assert response["lease"]["active"] == true
    assert response["lease"]["claimed_at"]
    assert response["lease"]["expires_at"]

    original_expiry = response["lease"]["expires_at"]

    conn =
      conn
      |> recycle()
      |> authed(token)
      |> post(~p"/api/jobs/#{task.id}/claim")

    repeated = json_response(conn, 200)
    assert repeated["claimant"]["id"] == worker.id
    assert repeated["lease"]["expires_at"] == original_expiry
  end

  test "creators may claim their own jobs; active claims conflict for others", %{
    conn: conn,
    creator: creator,
    creator_token: creator_token,
    repository: repository,
    worker_token: worker_token
  } do
    task = review_task_fixture(repository, creator)

    # Solo/hosted workflow: job creators may claim and perform their own Jobs.
    conn1 = conn |> authed(creator_token) |> post(~p"/api/jobs/#{task.id}/claim")
    assert json_response(conn1, 200)["claimant"]["id"] == creator.id

    conn_release =
      conn |> recycle() |> authed(creator_token) |> delete(~p"/api/jobs/#{task.id}/claim")

    assert json_response(conn_release, 200)["status"] == "open"

    conn2 = conn |> recycle() |> authed(worker_token) |> post(~p"/api/jobs/#{task.id}/claim")
    assert json_response(conn2, 200)

    outsider = account_fixture()
    outsider_token = client_token(outsider)

    conn3 = conn |> recycle() |> authed(outsider_token) |> post(~p"/api/jobs/#{task.id}/claim")
    assert json_response(conn3, 409)["error"] =~ "active claim"
  end

  test "only the claimant can release a task", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker: worker,
    worker_token: worker_token
  } do
    task = review_task_fixture(repository, creator)
    {:ok, task} = Work.claim_task(task, worker)
    outsider_token = client_token(account_fixture())

    conn1 = conn |> authed(outsider_token) |> delete(~p"/api/jobs/#{task.id}/claim")
    assert json_response(conn1, 403)["error"] =~ "current claimant"

    conn2 =
      conn
      |> recycle()
      |> authed(worker_token)
      |> delete(~p"/api/jobs/#{task.id}/claim")

    response = json_response(conn2, 200)
    assert response["status"] == "open"
    assert response["claimant"] == nil
    assert response["lease"] == nil
  end

  test "claimant can renew an active lease", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker_token: token
  } do
    task = review_task_fixture(repository, creator)

    conn = conn |> authed(token) |> post(~p"/api/jobs/#{task.id}/claim")
    first = json_response(conn, 200)

    conn =
      conn
      |> recycle()
      |> authed(token)
      |> post(~p"/api/jobs/#{task.id}/claim/renew")

    renewed = json_response(conn, 200)
    assert renewed["lease"]["active"]
    assert renewed["lease"]["expires_at"] >= first["lease"]["expires_at"]
  end

  test "completion path submits a claimed task for independent review", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker: worker,
    worker_token: token
  } do
    task = review_task_fixture(repository, creator)
    {:ok, task} = Work.claim_task(task, worker)

    body = %{
      "provenance" => "hybrid",
      "summary" => "The authorization boundary is enforced.",
      "evidence" => "Reviewed both entry points and ran the focused regression test."
    }

    conn = conn |> authed(token) |> post(~p"/api/jobs/#{task.id}/complete", body)

    response = json_response(conn, 200)
    assert response["status"] == "submitted"
    assert response["visibility"] == "public"
    assert response["submitted_at"]
    assert response["completed_at"] == nil
    assert response["lease"]["active"] == false

    assert response["contribution"] == %{
             "contributor" => %{
               "handle" => worker.handle,
               "id" => worker.id
             },
             "evidence" => body["evidence"],
             "id" => response["contribution"]["id"],
             "version" => 1,
             "provenance" => "hybrid",
             "submitted_at" => response["contribution"]["submitted_at"],
             "summary" => body["summary"]
           }

    conn2 =
      conn
      |> recycle()
      |> authed(token)
      |> delete(~p"/api/jobs/#{task.id}/claim")

    assert json_response(conn2, 403)["error"] =~ "current claimant"
  end

  test "completion requires the active claimant and valid evidence metadata", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker: worker,
    worker_token: token
  } do
    task = review_task_fixture(repository, creator)

    conn1 =
      conn
      |> authed(token)
      |> post(~p"/api/jobs/#{task.id}/complete", %{
        "provenance" => "human",
        "summary" => "Completed",
        "evidence" => "Attempted submission without first holding the task's active claim."
      })

    assert json_response(conn1, 403)["error"] =~ "current claimant"

    {:ok, _task} = Work.claim_task(task, worker)

    conn2 =
      conn
      |> recycle()
      |> authed(token)
      |> post(~p"/api/jobs/#{task.id}/complete", %{
        "provenance" => "unverifiable",
        "summary" => ""
      })

    errors = json_response(conn2, 422)["errors"]
    assert errors["provenance"] == ["is invalid"]
    assert errors["summary"] == ["can't be blank"]
  end

  test "completion provenance must satisfy the requested capability", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker: worker,
    worker_token: token
  } do
    task = review_task_fixture(repository, creator, %{"capability" => "hybrid"})
    {:ok, _task} = Work.claim_task(task, worker)

    conn =
      conn
      |> authed(token)
      |> post(~p"/api/jobs/#{task.id}/complete", %{
        "provenance" => "human",
        "summary" => "Manual review completed.",
        "evidence" => "Manually traced the requested paths and recorded reproducible notes."
      })

    assert json_response(conn, 422)["errors"]["provenance"] == [
             "does not satisfy this task's required capability"
           ]
  end

  test "proposals are publicly listed and publishing is not exposed to client credentials", %{
    conn: conn,
    creator: creator,
    repository: repository,
    creator_token: creator_token,
    worker_token: worker_token
  } do
    proposal = proposed_review_task_fixture(repository, creator)

    conn1 =
      conn
      |> authed(worker_token)
      |> get(~p"/api/github.com/openai/codex/jobs")

    assert [listed] = json_response(conn1, 200)["jobs"]
    assert listed["id"] == proposal.id
    assert listed["status"] == "proposed"
    assert listed["visibility"] == "public"

    conn2 =
      conn
      |> recycle()
      |> authed(creator_token)
      |> get(~p"/api/jobs/#{proposal.id}")

    assert json_response(conn2, 200)["status"] == "proposed"

    moderator = moderator_account_fixture()
    moderator_token = Accounts.create_account_api_token(moderator)

    conn3 =
      conn
      |> recycle()
      |> authed(moderator_token)
      |> post("/api/jobs/#{proposal.id}/publish", %{
        "reason" => "The task scope is safe, bounded, and useful to contributors."
      })

    assert response(conn3, 404) == "Not Found"

    assert {:ok, open} =
             Work.publish_task(proposal, moderator, %{
               "reason" => "The task scope is safe, bounded, and useful to contributors."
             })

    assert open.status == "open"
  end

  test "acceptance is not exposed to client credentials", %{
    conn: conn,
    creator: creator,
    repository: repository,
    worker: worker,
    worker_token: worker_token
  } do
    task = review_task_fixture(repository, creator)
    {:ok, task} = Work.claim_task(task, worker)

    {:ok, submitted} =
      Work.submit_task(task, worker, %{
        "provenance" => "human",
        "summary" => "The requested boundary was independently traced.",
        "evidence" => "Ran the negative authorization suite against both repository entry points."
      })

    conn1 =
      conn
      |> authed(worker_token)
      |> post("/api/jobs/#{submitted.id}/accept", %{
        "reason" => "I should not be allowed to approve my own contribution.",
        "evidence" => "This evidence comes from the original contributor and is not independent."
      })

    assert response(conn1, 404) == "Not Found"

    reviewer = moderator_account_fixture()
    reviewer_token = Accounts.create_account_api_token(reviewer)
    assert Work.get_visible_task(submitted.id, Tarakan.Accounts.Scope.for_account(reviewer))

    conn2 =
      conn
      |> recycle()
      |> authed(reviewer_token)
      |> post("/api/jobs/#{submitted.id}/accept", %{
        "reason" => "The result was independently reproduced at the pinned commit.",
        "evidence" => "Checked out the pinned SHA and ran the documented negative-path tests."
      })

    assert response(conn2, 404) == "Not Found"

    assert {:ok, accepted} =
             Work.accept_task(submitted, reviewer, %{
               "reason" => "The result was independently reproduced at the pinned commit.",
               "evidence" =>
                 "Checked out the pinned SHA and ran the documented negative-path tests."
             })

    assert accepted.status == "accepted"
    assert accepted.visibility == "public"

    outsider = account_fixture()
    outsider_token = Accounts.create_account_api_token(outsider)

    conn3 =
      conn
      |> recycle()
      |> authed(outsider_token)
      |> get(~p"/api/jobs/#{accepted.id}")

    response = json_response(conn3, 200)
    assert response["status"] == "accepted"
    assert response["visibility"] == "public"
    assert response["contribution"]["summary"] =~ "boundary"
    assert response["contribution"]["evidence"] =~ "negative authorization suite"

    assert {:ok, redacted} =
             Work.disclose_task(accepted, reviewer, "public_summary", %{
               "reason" =>
                 "The redacted result is safe and useful without publishing raw evidence."
             })

    conn4 =
      conn
      |> recycle()
      |> authed(outsider_token)
      |> get(~p"/api/jobs/#{redacted.id}")

    response = json_response(conn4, 200)
    assert response["visibility"] == "public_summary"
    assert response["contribution"]["summary"] =~ "boundary"
    assert response["contribution"]["evidence"] == nil
    assert response["decisions"] == []
    assert response["disclosed_at"]
    assert response["sensitive_data_reviewed"] == false
  end
end
