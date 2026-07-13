defmodule TarakanWeb.SEOControllerTest do
  use TarakanWeb.ConnCase

  test "robots.txt allows crawling and points at the sitemap", %{conn: conn} do
    response = conn |> get(~p"/robots.txt") |> text_response(200)

    assert response =~ "User-agent: *"
    assert response =~ "Allow: /"
    assert response =~ "Sitemap: " <> TarakanWeb.Endpoint.url() <> "/sitemap.xml"
  end

  test "the sitemap lists the home page, listed repositories, and public findings", %{
    conn: conn
  } do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)

    scan =
      repository
      |> scan_fixture(submitter, %{"findings_json" => findings_json_fixture(2)})
      |> publish_scan("public")

    response = conn |> get(~p"/sitemap.xml") |> response(200)
    base = TarakanWeb.Endpoint.url()

    assert response =~ ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
    assert response =~ "<loc>#{base}/</loc>"
    assert response =~ "<loc>#{base}/github.com/openai/codex/security</loc>"

    for finding <- scan.findings do
      assert response =~ "<loc>#{base}/findings/#{finding.public_id}</loc>"
    end
  end

  test "the sitemap indexes fresh findings but not restricted or summary ones", %{conn: conn} do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)

    fresh = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})

    restricted =
      scan_fixture(repository, account_fixture(), %{"findings_json" => findings_json_fixture(1)})

    {:ok, _restricted} =
      Tarakan.Scans.update_visibility(
        Tarakan.Accounts.Scope.for_account(moderator_account_fixture()),
        restricted,
        "restricted",
        %{
          "moderation_reason" => "takedown_review",
          "moderation_notes" =>
            "Deliberately restricted in this test to keep it out of search discovery."
        }
      )

    summary =
      scan_fixture(repository, account_fixture(), %{"findings_json" => findings_json_fixture(1)})

    publish_scan(summary, "public_summary")

    response = conn |> get(~p"/sitemap.xml") |> response(200)

    for finding <- fresh.findings do
      assert response =~ "/findings/#{finding.public_id}"
    end

    for scan <- [restricted, summary], finding <- scan.findings do
      refute response =~ to_string(finding.public_id)
    end
  end

  test "quarantined repositories stay out of the sitemap", %{conn: conn} do
    repository = github_repository_fixture()

    repository
    |> Tarakan.Repositories.Repository.listing_changeset(%{listing_status: "quarantined"})
    |> Tarakan.Repo.update!()

    response = conn |> get(~p"/sitemap.xml") |> response(200)

    refute response =~ "openai/codex"
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
