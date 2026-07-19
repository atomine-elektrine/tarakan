defmodule TarakanWeb.FindingLiveTest do
  use TarakanWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    %{repository: repository, submitter: submitter}
  end

  test "renders a publicly disclosed finding", %{
    conn: conn,
    repository: repository,
    submitter: submitter
  } do
    scan =
      repository
      |> scan_fixture(submitter, %{"findings_json" => findings_json_fixture(1)})
      |> publish_scan("public")

    [finding] = scan.findings

    {:ok, view, html} = live(conn, ~p"/findings/#{finding.public_id}")

    assert has_element?(view, "#finding-title", finding.title)
    assert has_element?(view, "#finding-severity", "high")
    assert has_element?(view, "#finding-description", "String-built SQL")
    assert has_element?(view, "#finding-canonical-memory", "detected in 1 run")
    assert has_element?(view, "#finding-source-link[href='/findings/#{finding.public_id}/code']")
    assert has_element?(view, "#finding-verified-badge")
    assert has_element?(view, "#finding-disclosure-badge")
    assert has_element?(view, "#finding-copy-link")
    assert has_element?(view, "#finding-cite", "/findings/#{finding.public_id}")
    assert has_element?(view, "#finding-verdict-counts", "2 confirmed · 0 disputed")
    assert html =~ scan.commit_sha
    assert html =~ "Public"
    assert has_element?(view, "#finding-record-link[href='/github.com/openai/codex/security']")
  end

  test "shows the raw model report exactly as submitted", %{
    conn: conn,
    repository: repository,
    submitter: submitter
  } do
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings

    assert scan.raw_document == findings_json_fixture(1)

    {:ok, view, html} = live(conn, ~p"/findings/#{finding.public_id}")

    assert has_element?(view, "#finding-raw-report")
    assert html =~ "tarakan_scan_format"
  end

  test "a qualified contributor records a verdict from the finding page", %{
    conn: conn,
    repository: repository,
    submitter: submitter
  } do
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings

    reviewer =
      account_fixture()
      |> Tarakan.Accounts.Account.authorization_changeset(%{
        state: "active",
        platform_role: "member",
        trust_tier: "reviewer"
      })
      |> Tarakan.Repo.update!()

    conn = log_in_account(conn, reviewer)
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")

    assert has_element?(view, "#finding-verdict-counts", "0 confirmed · 0 disputed")

    view
    |> form("#finding-verdict-form", %{
      "notes" => "Reproduced against the pinned commit with the documented payload."
    })
    |> render_submit(%{"verdict" => "confirmed"})

    assert has_element?(view, "#finding-verdict-counts", "1 confirmed · 0 disputed")
    assert has_element?(view, "#finding-checks", "@#{reviewer.handle}")

    assert has_element?(
             view,
             "#finding-checks",
             "Reproduced against the pinned commit with the documented payload."
           )

    assert has_element?(view, "#finding-checks", "counts toward quorum")
    refute has_element?(view, "#finding-verdict-form")

    {:ok, public_view, _html} =
      live(Phoenix.ConnTest.build_conn(), ~p"/findings/#{finding.public_id}")

    assert has_element?(public_view, "#finding-checks", "@#{reviewer.handle}")
    assert has_element?(public_view, "#finding-checks", "documented payload")
  end

  test "the submitter cannot verify their own finding", %{
    conn: conn,
    repository: repository,
    submitter: submitter
  } do
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings

    conn = log_in_account(conn, submitter)
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")

    refute has_element?(view, "#finding-verdict-form")
  end

  test "the dead render carries the meta description and canonical URL", %{
    conn: conn,
    repository: repository,
    submitter: submitter
  } do
    scan =
      repository
      |> scan_fixture(submitter, %{"findings_json" => findings_json_fixture(1)})
      |> publish_scan("public")

    [finding] = scan.findings

    html = conn |> get(~p"/findings/#{finding.public_id}") |> html_response(200)

    assert html =~ ~s(rel="canonical")
    assert html =~ "/findings/#{finding.public_id}"
    assert html =~ "High in openai/codex"
    assert get_resp_header(get(conn, ~p"/findings/#{finding.public_id}"), "x-robots-tag") == []
  end

  test "fresh submissions resolve for anonymous visitors immediately", %{
    conn: conn,
    repository: repository,
    submitter: submitter
  } do
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings

    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")

    assert has_element?(view, "#finding-title", finding.title)
    refute has_element?(view, "#finding-verified-badge")
  end

  test "restricted findings do not resolve for anonymous visitors", %{
    conn: conn,
    repository: repository,
    submitter: submitter
  } do
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings

    {:ok, _restricted} =
      Tarakan.Scans.update_visibility(
        Tarakan.Accounts.Scope.for_account(moderator_account_fixture()),
        scan,
        "restricted",
        %{
          "moderation_reason" => "takedown_review",
          "moderation_notes" =>
            "Deliberately restricted in this test to exercise the takedown boundary."
        }
      )

    assert_error_sent 404, fn -> get(conn, ~p"/findings/#{finding.public_id}") end
  end

  test "public-summary findings do not resolve for anonymous visitors", %{
    conn: conn,
    repository: repository,
    submitter: submitter
  } do
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings
    publish_scan(scan, "public_summary")

    assert_error_sent 404, fn -> get(conn, ~p"/findings/#{finding.public_id}") end
  end

  test "the submitter can still open their own restricted finding", %{
    conn: conn,
    repository: repository,
    submitter: submitter
  } do
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    [finding] = scan.findings

    {:ok, _restricted} =
      Tarakan.Scans.update_visibility(
        Tarakan.Accounts.Scope.for_account(moderator_account_fixture()),
        scan,
        "restricted",
        %{
          "moderation_reason" => "takedown_review",
          "moderation_notes" =>
            "Deliberately restricted in this test to exercise submitter access."
        }
      )

    conn = log_in_account(conn, submitter)
    {:ok, view, _html} = live(conn, ~p"/findings/#{finding.public_id}")

    assert has_element?(view, "#finding-title", finding.title)
  end

  defp publish_scan(scan, visibility) do
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
      Tarakan.Scans.accept_scan(scope, scan, %{
        "moderation_reason" => "evidence_reviewed",
        "moderation_notes" =>
          "Two independent reviewers supplied reproducible evidence for the pinned commit."
      })

    {:ok, scan} =
      Tarakan.Scans.update_visibility(scope, scan, visibility, %{
        "moderation_reason" => "disclosure_reviewed",
        "moderation_notes" =>
          "Disclosure was separately reviewed for scope, secrets, and personal data.",
        "sensitive_data_reviewed" => "true"
      })

    scan
  end
end
