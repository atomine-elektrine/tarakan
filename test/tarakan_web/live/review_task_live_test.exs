defmodule TarakanWeb.ReviewTaskLiveTest do
  use TarakanWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    creator = github_account_fixture()
    repository = listed_github_repository_fixture(creator)
    task = review_task_fixture(repository, creator)

    %{conn: conn, creator: creator, repository: repository, task: task}
  end

  test "the public can inspect a task but cannot claim anonymously", %{conn: conn, task: task} do
    {:ok, view, _html} = live(conn, ~p"/jobs/#{task.id}")

    assert has_element?(view, "#review-task-title")
    assert has_element?(view, "#review-task-status", "Open")
    refute has_element?(view, "#claim-review-task-button")

    html = render_hook(view, "claim", %{})
    assert html =~ "not authorized"

    html = render_hook(view, "review", %{"action" => "invented", "decision" => %{}})
    assert html =~ "review action is invalid"

    assert {:error, {:live_redirect, %{to: "/accounts/log-in?return_to=%2Fjobs%2F" <> _}}} =
             render_hook(view, "publish", %{"decision" => %{}})
  end

  test "the task creator may claim and perform their own job", %{
    conn: conn,
    creator: creator,
    task: task
  } do
    conn = log_in_account(conn, creator)
    {:ok, view, _html} = live(conn, ~p"/jobs/#{task.id}")

    assert has_element?(view, "#claim-review-task-button")
    refute has_element?(view, "#review-task-own-notice")

    view |> element("#claim-review-task-button") |> render_click()
    assert has_element?(view, "#review-task-status", "Claimed")
    assert has_element?(view, "#review-task-completion-form")
    refute has_element?(view, "#review-task-agent-path")
  end

  test "agent-required jobs show the CLI path instead of free-text completion", %{
    conn: conn,
    creator: creator,
    repository: repository
  } do
    task =
      review_task_fixture(repository, creator, %{
        "kind" => "code_review",
        "capability" => "agent",
        "title" => "Agent code review of auth boundaries"
      })

    worker = account_fixture()
    conn = log_in_account(conn, worker)
    {:ok, view, _html} = live(conn, ~p"/jobs/#{task.id}")

    assert has_element?(view, "#review-task-title")
    assert has_element?(view, "#review-task", "Agent required")

    view |> element("#claim-review-task-button") |> render_click()

    assert has_element?(view, "#review-task-status", "Claimed")
    assert has_element?(view, "#review-task-agent-path")
    refute has_element?(view, "#review-task-completion-form")
    assert render(view) =~ "tarakan report"
    assert render(view) =~ "--job #{task.id}"
  end

  test "agent check jobs show only the check command and their target findings", %{
    conn: conn,
    creator: creator,
    repository: repository
  } do
    report =
      scan_fixture(repository, account_fixture(), %{"findings_json" => findings_json_fixture()})

    task =
      review_task_fixture(repository, creator, %{
        "kind" => "verify_findings",
        "capability" => "agent",
        "target_review_id" => report.id,
        "title" => "Independently check the report"
      })

    worker = reviewer_account_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_account(worker)
      |> live(~p"/jobs/#{task.id}")

    assert has_element?(view, "#review-task-target-report", "Target report ##{report.id}")
    assert has_element?(view, "#review-task-target-report", "Unsanitized input")

    view |> element("#claim-review-task-button") |> render_click()

    assert has_element?(view, "#review-task-agent-path")
    assert render(view) =~ "tarakan worker --agent grok --once --jobs-only"
    refute render(view) =~ "tarakan report"
  end

  test "a hybrid claimant can verify a report from the web", %{
    conn: conn,
    creator: creator,
    repository: repository
  } do
    report =
      scan_fixture(repository, account_fixture(), %{"findings_json" => findings_json_fixture()})

    task =
      review_task_fixture(repository, creator, %{
        "kind" => "verify_findings",
        "capability" => "hybrid",
        "target_review_id" => report.id,
        "title" => "Reproduce the reported data flow"
      })

    worker = reviewer_account_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_account(worker)
      |> live(~p"/jobs/#{task.id}")

    view |> element("#claim-review-task-button") |> render_click()

    assert has_element?(view, "#review-task-verification-form")
    refute has_element?(view, "#review-task-completion-form")

    view
    |> form("#review-task-verification-form",
      verification: %{
        provenance: "hybrid",
        verdict: "confirmed",
        notes: "Reproduced every reported path against the exact pinned commit.",
        evidence: "Ran the negative-path request and observed the authorization bypass."
      }
    )
    |> render_submit()

    assert has_element?(view, "#review-task-status", "Submitted")
    assert has_element?(view, "#review-task-target-confirmations", "authorization bypass")
    assert Tarakan.Work.get_task!(task.id).linked_review_id == report.id
  end

  test "agent fix jobs show the autonomous patch workflow", %{
    conn: conn,
    creator: creator,
    repository: repository
  } do
    task =
      review_task_fixture(repository, creator, %{
        "kind" => "write_fix",
        "capability" => "agent",
        "title" => "Patch the authorization bypass"
      })

    worker = account_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_account(worker)
      |> live(~p"/jobs/#{task.id}")

    view |> element("#claim-review-task-button") |> render_click()

    assert has_element?(view, "#review-task-agent-path", "reviewable unified diff")
    assert render(view) =~ "tarakan worker --agent grok --once --jobs-only"
    refute render(view) =~ "tarakan report"
  end

  test "a proposed fix is rendered as a patch artifact", %{
    conn: conn,
    creator: creator,
    repository: repository
  } do
    task =
      review_task_fixture(repository, creator, %{
        "kind" => "write_fix",
        "capability" => "human",
        "title" => "Patch the authorization bypass"
      })

    worker = account_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_account(worker)
      |> live(~p"/jobs/#{task.id}")

    view |> element("#claim-review-task-button") |> render_click()

    assert has_element?(
             view,
             "#review-task-completion-form",
             "Proposed unified diff and test plan"
           )

    view
    |> form("#review-task-completion-form",
      contribution: %{
        provenance: "human",
        summary: "Require ownership before the state transition.",
        evidence:
          "diff --git a/lib/action.ex b/lib/action.ex\n--- a/lib/action.ex\n+++ b/lib/action.ex\n@@ -1 +1,2 @@\n run()\n+authorize()\n\nTest: mix test"
      }
    )
    |> render_submit()

    assert has_element?(view, "#review-task-fix-badge", "Patch proposal")
    assert has_element?(view, "#review-task-contribution", "Proposed fix")
    assert has_element?(view, "#review-task-contribution", "diff --git")
    refute has_element?(view, "#review-task-historical-badge")
  end

  test "another contributor claims and submits the task for review", %{conn: conn, task: task} do
    worker = account_fixture()
    conn = log_in_account(conn, worker)
    {:ok, view, _html} = live(conn, ~p"/jobs/#{task.id}")

    view |> element("#claim-review-task-button") |> render_click()

    assert has_element?(view, "#review-task-status", "Claimed")
    assert has_element?(view, "#review-task-completion-form")
    refute has_element?(view, "#review-task-agent-path")

    view
    |> form("#review-task-completion-form",
      contribution: %{
        provenance: "human",
        summary: "The boundary is enforced consistently.",
        evidence: "Reproduced the negative path with the repository test suite."
      }
    )
    |> render_submit()

    assert has_element?(view, "#review-task-status", "Submitted")
    assert has_element?(view, "#review-task-review-pending")
    assert has_element?(view, "#review-task-contribution", "Human")
    assert has_element?(view, "#review-task-contribution", "boundary is enforced")
    refute has_element?(view, "#review-task-completion-form")
  end

  test "a qualified independent reviewer accepts submitted evidence", %{
    conn: conn,
    task: task
  } do
    worker = account_fixture()
    {:ok, task} = Tarakan.Work.claim_task(task, worker)

    {:ok, task} =
      Tarakan.Work.submit_task(task, worker, %{
        "provenance" => "human",
        "summary" => "The boundary is enforced consistently.",
        "evidence" => "Reproduced the negative path with the repository test suite."
      })

    reviewer = moderator_account_fixture()
    conn = log_in_account(conn, reviewer)
    {:ok, view, _html} = live(conn, ~p"/jobs/#{task.id}")

    assert has_element?(view, "#review-task-decision-form")

    view
    |> form("#review-task-decision-form",
      decision: %{
        reason: "The submitted behavior was reproduced independently.",
        evidence: "Checked out the pinned SHA and ran the documented negative-path tests."
      }
    )
    |> render_submit(%{"action" => "accept"})

    assert has_element?(view, "#review-task-status", "Accepted")
    assert has_element?(view, "#review-task-visibility", "Full evidence public")
    assert has_element?(view, "#review-task-contribution")
    assert has_element?(view, "#review-task-disclosure-form")
    refute has_element?(view, "#review-task-decision-form")
    assert Tarakan.Work.get_visible_task(task.id)

    {:ok, accepted_view, accepted_html} =
      live(Phoenix.ConnTest.build_conn(), ~p"/jobs/#{task.id}")

    assert has_element?(accepted_view, "#review-task-status", "Accepted")
    assert accepted_html =~ "Reproduced the negative path"

    html =
      view
      |> form("#review-task-disclosure-form", disclosure: %{reason: "short"})
      |> render_submit(%{"visibility" => "public_summary"})

    assert html =~ "should be at least 10 character"
    assert Tarakan.Work.get_task!(task.id).visibility == "public"

    view
    |> form("#review-task-disclosure-form",
      disclosure: %{
        reason: "The redacted result is safe and useful to publish without raw evidence."
      }
    )
    |> render_submit(%{"visibility" => "public_summary"})

    assert has_element?(view, "#review-task-visibility", "Public summary")

    {:ok, public_view, public_html} =
      live(Phoenix.ConnTest.build_conn(), ~p"/jobs/#{task.id}")

    assert has_element?(public_view, "#review-task-status", "Accepted")
    assert public_html =~ "boundary is enforced"
    refute public_html =~ "Reproduced the negative path"
    refute public_html =~ "documented negative-path tests"
  end

  test "disclosure requires recent authentication", %{conn: conn, task: task} do
    worker = account_fixture()
    {:ok, task} = Tarakan.Work.claim_task(task, worker)

    {:ok, task} =
      Tarakan.Work.submit_task(task, worker, %{
        "provenance" => "human",
        "summary" => "The boundary is enforced consistently.",
        "evidence" => "Reproduced the negative path with the repository test suite."
      })

    reviewer = moderator_account_fixture()

    {:ok, task} =
      Tarakan.Work.accept_task(task, reviewer, %{
        "reason" => "The submitted behavior was reproduced independently.",
        "evidence" => "Checked out the pinned SHA and ran the documented negative-path tests."
      })

    # Outside the two-hour sudo window.
    stale_at = DateTime.add(DateTime.utc_now(), -3, :hour)
    conn = log_in_account(conn, reviewer, token_authenticated_at: stale_at)
    {:ok, view, _html} = live(conn, ~p"/jobs/#{task.id}")

    assert {:error, {:live_redirect, %{to: "/accounts/log-in?return_to=%2Fjobs%2F" <> _}}} =
             view
             |> form("#review-task-disclosure-form",
               disclosure: %{
                 reason: "The redacted result is safe and useful to publish without raw evidence."
               }
             )
             |> render_submit(%{"visibility" => "public_summary"})

    assert Tarakan.Work.get_task!(task.id).visibility == "public"
  end

  test "a claimant can release work back to the queue", %{conn: conn, task: task} do
    worker = account_fixture()
    conn = log_in_account(conn, worker)
    {:ok, view, _html} = live(conn, ~p"/jobs/#{task.id}")

    view |> element("#claim-review-task-button") |> render_click()
    view |> element("#release-review-task-button") |> render_click()

    assert has_element?(view, "#review-task-status", "Open")
    assert has_element?(view, "#claim-review-task-button")
  end
end
