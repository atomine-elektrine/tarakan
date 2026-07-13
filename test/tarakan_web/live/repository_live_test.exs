defmodule TarakanWeb.RepositoryLiveTest do
  use TarakanWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository
  alias Tarakan.Work

  test "renders the public repository registry", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#repository-auth-gate")
    assert has_element?(view, "#account-login-button")
    refute has_element?(view, "#activity-wire")
    assert has_element?(view, "#registry-shoutbox")
  end

  test "scan queue excludes quarantined repositories", %{conn: conn} do
    repository = github_repository_fixture()

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#scan-queue-#{repository.id}", "★")

    quarantined =
      repository
      |> Repository.listing_changeset(%{listing_status: "quarantined"})
      |> Tarakan.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#scan-queue-#{quarantined.id}")
  end

  test "lists registrations in the public registry immediately", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    account = github_account_fixture()

    {:ok, repository} =
      Repositories.register_github_repository("github.com/OpenAI/Codex", account)

    _ = :sys.get_state(view.pid)

    assert repository.listing_status == "listed"
    assert has_element?(view, "#scan-queue-#{repository.id}")
    assert has_element?(view, "#repository-count", "1")
  end

  test "resolved repository containment evicts connected public repository and task views", %{
    conn: conn
  } do
    creator = github_account_fixture()
    repository = listed_github_repository_fixture(creator)
    task = review_task_fixture(repository, creator)
    {:ok, repository_view, _html} = live(conn, ~p"/github.com/openai/codex/security")
    {:ok, task_view, _html} = live(conn, ~p"/work/#{task.id}")

    reporter = account_fixture()
    moderator = moderator_account_fixture()

    assert {:ok, case_record} =
             Tarakan.Moderation.report(
               Tarakan.Accounts.Scope.for_account(reporter),
               %{
                 "subject_type" => "repository",
                 "subject_id" => repository.id,
                 "reason" => "unsafe_disclosure",
                 "description" =>
                   "The public repository record contains disclosure material that needs review."
               }
             )

    assert {:ok, assigned} =
             Tarakan.Moderation.assign(
               Tarakan.Accounts.Scope.for_account(moderator),
               case_record
             )

    assert {:ok, _resolved} =
             Tarakan.Moderation.resolve(
               Tarakan.Accounts.Scope.for_account(moderator),
               assigned,
               "resolved",
               "The report was verified and the public record must remain contained."
             )

    assert_redirect(repository_view, ~p"/")
    assert_redirect(task_view, ~p"/github.com/openai/codex")

    contained = Tarakan.Repo.get!(Repository, repository.id)
    assert contained.participation_mode == "paused"
    assert contained.listing_status == "quarantined"
  end

  describe "registry search" do
    test "finds a listed repository by partial name and links to its record", %{conn: conn} do
      repository = github_repository_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#repository-search-form", %{"q" => "ope"})
      |> render_change()

      assert has_element?(view, "#search-result-#{repository.id}", "openai/codex")

      assert view |> element("#search-result-#{repository.id}") |> render() =~
               ~s(href="/github.com/openai/codex")
    end

    test "matches the combined owner/name form", %{conn: conn} do
      repository = github_repository_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#repository-search-form", %{"q" => "openai/co"})
      |> render_change()

      assert has_element?(view, "#search-result-#{repository.id}", "openai/codex")
    end

    test "never lists quarantined repositories", %{conn: conn} do
      repository =
        github_repository_fixture()
        |> Repository.listing_changeset(%{listing_status: "quarantined"})
        |> Tarakan.Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#repository-search-form", %{"q" => "codex"})
      |> render_change()

      refute has_element?(view, "#search-result-#{repository.id}")
      assert has_element?(view, "#repository-search-results", "No repositories match")
    end

    test "renders no results panel for a blank query", %{conn: conn} do
      github_repository_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#repository-search-results")

      view
      |> form("#repository-search-form", %{"q" => "   "})
      |> render_change()

      refute has_element?(view, "#repository-search-results")
    end

    test "treats ilike metacharacters as literals", %{conn: conn} do
      repository = github_repository_fixture()
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#repository-search-form", %{"q" => "%"})
      |> render_change()

      refute has_element?(view, "#search-result-#{repository.id}")
      assert has_element?(view, "#repository-search-results", "No repositories match “%”")
    end
  end

  describe "security record" do
    setup %{conn: conn} do
      submitter = github_account_fixture()
      repository = listed_github_repository_fixture(submitter)
      %{conn: conn, submitter: submitter, repository: repository}
    end

    test "logged-out visitors see fresh submissions but not moderator-restricted scans", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})

      restricted =
        scan_fixture(repository, account_fixture(), %{"findings_json" => findings_json_fixture(1)})

      {:ok, restricted} =
        Tarakan.Scans.update_visibility(
          Tarakan.Accounts.Scope.for_account(moderator_account_fixture()),
          restricted,
          "restricted",
          %{
            "moderation_reason" => "evidence_reviewed",
            "moderation_notes" =>
              "The disclosure needs moderator review and is taken down in the meantime."
          }
        )

      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      assert has_element?(view, "#scans-#{scan.id}", "Submitted (not accepted)")
      assert has_element?(view, "#scans-#{scan.id}", "1 finding")
      assert has_element?(view, "#scans-#{scan.id}", "lib/example/module_1.ex")
      refute has_element?(view, "#scans-#{restricted.id}")
      refute has_element?(view, "#scan-api-pointer")
      refute has_element?(view, "#scan-submission-form")
      refute has_element?(view, "#scan-#{scan.id}-verdict-form")
    end

    test "authorization changes evict stale LiveView snapshots", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})

      {:ok, view, _html} =
        live(log_in_account(conn, submitter), ~p"/github.com/openai/codex/security")

      assert has_element?(view, "#scans-#{scan.id}")

      admin =
        account_fixture()
        |> Tarakan.Accounts.Account.authorization_changeset(%{
          state: "active",
          platform_role: "admin"
        })
        |> Tarakan.Repo.update!()

      assert {:ok, _suspended} =
               Tarakan.Accounts.update_authorization(
                 Tarakan.Accounts.Scope.for_account(admin),
                 submitter,
                 %{state: "suspended"}
               )

      assert_redirect(view, ~p"/")
    end

    test "renders clean and findings scans with the repository state", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      findings_scan =
        repository
        |> scan_fixture(submitter, %{"findings_json" => findings_json_fixture(2)})
        |> publish_scan("public")

      repository
      |> scan_fixture(account_fixture(), %{"findings_json" => nil})
      |> publish_scan("public")

      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      assert has_element?(view, "#scans article", "No findings reported")
      assert has_element?(view, "#scans article", "2 findings")
      assert has_element?(view, "#scans article", "lib/example/module_1.ex:10-15")
      assert has_element?(view, "#repository-status", "findings")
      assert has_element?(view, "#scan-count", "2")
      assert has_element?(view, "#open-findings-count", "2")
      assert has_element?(view, "#canonical-findings", "2 unique open")

      assert has_element?(view, "#canonical-findings article + article")

      for finding <- findings_scan.findings do
        assert has_element?(
                 view,
                 "#finding-source-#{finding.id}[href='/findings/#{finding.public_id}/code']"
               )
      end
    end

    test "assimilates repeated report findings into one public issue", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      commit_sha = random_commit_sha()
      document = findings_json_fixture(1)

      scan_fixture(repository, submitter, %{
        "commit_sha" => commit_sha,
        "findings_json" => document
      })

      scan_fixture(repository, account_fixture(), %{
        "commit_sha" => commit_sha,
        "findings_json" => document
      })

      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      assert has_element?(view, "#scan-count", "2")
      assert has_element?(view, "#open-findings-count", "1")
      assert has_element?(view, "#canonical-findings", "detected in 2 runs")
      assert has_element?(view, "#canonical-findings", "2 submitters")

      assert has_element?(view, "#canonical-findings article[id^='canonical-']")
      refute has_element?(view, "#canonical-findings article + article")
    end

    test "public summaries do not disclose finding paths or source links", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      scan =
        repository
        |> scan_fixture(submitter, %{"findings_json" => findings_json_fixture(1)})
        |> publish_scan("public_summary")

      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")
      html = render(view)

      assert has_element?(view, "#scans-#{scan.id}", "Detailed evidence is restricted")
      refute html =~ "lib/example/module_1.ex"
      refute html =~ "/findings/"
      refute has_element?(view, "[id^='finding-source-']")
    end

    test "shows human provenance, review type, and narrative evidence", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      scan =
        repository
        |> scan_fixture(submitter, %{
          "provenance" => "human",
          "review_kind" => "privacy_review",
          "model" => nil,
          "prompt_version" => nil,
          "notes" => "Manually mapped deletion behavior across analytics exports."
        })
        |> publish_scan("public")

      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      assert has_element?(view, "#scans-#{scan.id}")
      assert has_element?(view, "#scans-#{scan.id}", "Written by a human")
      assert has_element?(view, "#scans-#{scan.id}", "Privacy review")
      assert has_element?(view, "#scans-#{scan.id}", "Manually mapped deletion behavior")
      assert has_element?(view, "#scans-#{scan.id}", "Reviewed")

      assert has_element?(
               view,
               "#scan-#{scan.id}-provenance-attestation[title='Submitter claim, not independently verified']"
             )
    end

    test "submitters see no verdict form on their own scan", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      scan = scan_fixture(repository, submitter)

      conn = log_in_account(conn, submitter)
      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      assert has_element?(view, "#scans-#{scan.id}")
      refute has_element?(view, "#scan-#{scan.id}-verdict-form")
    end

    test "records an independent check on one canonical finding", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
      [occurrence] = scan.findings
      canonical_id = occurrence.canonical_finding.public_id

      conn = log_in_account(conn, reviewer_account_fixture())
      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      view
      |> form("#canonical-#{canonical_id}-check-form")
      |> render_submit(%{
        "verdict" => "confirmed",
        "notes" => "Independently reproduced this one finding at the pinned commit."
      })

      assert has_element?(view, "#canonical-#{canonical_id}", "1 confirmed")
      refute has_element?(view, "#canonical-#{canonical_id}-check-form")
    end

    test "a moderator explicitly accepts and discloses verified evidence", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      scan =
        scan_fixture(repository, submitter) |> confirmation_fixture(reviewer_account_fixture())

      scan = confirmation_fixture(scan, reviewer_account_fixture())

      conn = log_in_account(conn, moderator_account_fixture())
      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      view
      |> form("#scan-#{scan.id}-moderation-form",
        moderation: %{
          "moderation_reason" => "evidence_reviewed",
          "moderation_notes" =>
            "Two independent reviewers supplied reproducible evidence for the pinned commit."
        }
      )
      |> render_submit(%{"decision" => "accept"})

      view
      |> form("#scan-#{scan.id}-moderation-form",
        moderation: %{
          "moderation_reason" => "safe_summary",
          "moderation_notes" =>
            "The public summary omits file paths, reproduction details, and verifier notes."
        }
      )
      |> render_submit(%{"decision" => "publish_summary"})

      assert has_element?(view, "#scans-#{scan.id}", "Accepted")
      assert has_element?(view, "#scans-#{scan.id}", "Restore full evidence")
      assert has_element?(view, "#repository-status", "reviewed")
      assert has_element?(view, "#scan-count", "1")
    end

    test "scan activity updates the registry stats live", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#unscanned-count", "1")

      scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(2)})
      publish_scan(scan)

      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#unscanned-count", "0")
      assert has_element?(view, "#verified-findings-count", "2")
    end

    test "streams scans submitted elsewhere onto the record live", %{
      conn: conn,
      repository: repository,
      submitter: submitter
    } do
      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      assert has_element?(view, "#scan-count", "0")
      assert has_element?(view, "#repository-status", "unscanned")

      scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})

      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#scans-#{scan.id}")
      assert has_element?(view, "#scan-count", "1")
      assert has_element?(view, "#repository-status", "findings")
    end
  end

  describe "human review queue" do
    setup %{conn: conn} do
      creator = github_account_fixture()
      repository = listed_github_repository_fixture(creator)
      %{conn: conn, creator: creator, repository: repository}
    end

    test "the public can see tasks and gets a sign-in gate", %{
      conn: conn,
      creator: creator,
      repository: repository
    } do
      task = review_task_fixture(repository, creator)
      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      assert has_element?(view, "#review-task-auth-gate")
      assert has_element?(view, "#tasks-#{task.id}")
      assert has_element?(view, "#review-task-#{task.id}-link")
      refute has_element?(view, "#review-task-form")
    end

    test "an authenticated contributor opens a task", %{
      conn: conn,
      creator: creator
    } do
      conn = log_in_account(conn, creator)
      {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")

      view |> element("#propose-task-toggle") |> render_click()

      view
      |> form("#review-task-form", review_task: valid_review_task_attributes())
      |> render_submit()

      assert has_element?(view, "#review-tasks article", "Map the authorization boundary")
      assert has_element?(view, "#review-tasks article", "Human-authored required")
    end

    test "a contributor can propose a check for an existing report", %{
      conn: conn,
      creator: creator,
      repository: repository
    } do
      report =
        scan_fixture(repository, account_fixture(), %{
          "findings_json" => findings_json_fixture()
        })

      {:ok, view, _html} =
        conn
        |> log_in_account(creator)
        |> live(~p"/github.com/openai/codex/security")

      view |> element("#propose-task-toggle") |> render_click()

      view
      |> form("#review-task-form", %{
        "review_task" => %{"kind" => "verify_findings"}
      })
      |> render_change()

      assert has_element?(view, "#review_task_target_review_id option[value='#{report.id}']")

      view
      |> form("#review-task-form", %{
        "review_task" =>
          valid_review_task_attributes(%{
            "kind" => "verify_findings",
            "target_review_id" => to_string(report.id),
            "title" => "Check the reported authorization bypass"
          })
      })
      |> render_submit()

      assert has_element?(
               view,
               "#review-tasks article",
               "Check the reported authorization bypass"
             )

      assert [%{target_review_id: target_review_id}] = Work.list_tasks(repository)
      assert target_review_id == report.id
    end
  end

  defp publish_scan(scan, visibility \\ "public_summary") do
    scan = confirmation_fixture(scan, reviewer_account_fixture())
    scan = confirmation_fixture(scan, reviewer_account_fixture())

    scope = Tarakan.Accounts.Scope.for_account(moderator_account_fixture())

    if visibility == "public" do
      scan.repository
      |> Tarakan.Repositories.Repository.participation_changeset(%{
        participation_mode: "maintainer_verified"
      })
      |> Tarakan.Repo.update!()
    end

    {:ok, scan} =
      Tarakan.Scans.accept_scan(
        scope,
        scan,
        %{
          "moderation_reason" => "evidence_reviewed",
          "moderation_notes" =>
            "Two independent reviewers supplied reproducible evidence for the pinned commit."
        }
      )

    {:ok, scan} =
      Tarakan.Scans.update_visibility(
        scope,
        scan,
        visibility,
        %{
          "moderation_reason" => "disclosure_reviewed",
          "moderation_notes" =>
            "Disclosure was separately reviewed for scope, secrets, and personal data.",
          "sensitive_data_reviewed" => "true"
        }
      )

    scan
  end

  test "raw reports are provenance-only and canonical findings own public signals", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings

    {:ok, view, _html} = live(conn, ~p"/github.com/openai/codex/security")
    refute has_element?(view, "#scan-sort")
    refute has_element?(view, "#scan-#{scan.id}-verdict-form")
    refute has_element?(view, "#vote-finding-#{finding.id}")
    assert has_element?(view, "#vote-canonical_finding-#{finding.canonical_finding.id}")
  end
end
