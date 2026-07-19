defmodule TarakanWeb.API.ScanControllerTest do
  use TarakanWeb.ConnCase, async: true

  alias Tarakan.Accounts.ApiCredentials
  alias Tarakan.Accounts.Scope
  alias Tarakan.Repositories
  alias Tarakan.Repositories.Repository
  alias Tarakan.Repo
  alias Tarakan.Scans

  setup %{conn: conn} do
    account = github_account_fixture()
    repository = github_repository_fixture(account)
    token = api_token(account)

    %{conn: conn, account: account, repository: repository, token: token}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp api_token(account) do
    {:ok, token, _credential} =
      ApiCredentials.create(account, %{
        name: "Scan submitter",
        scopes: ["findings:submit"]
      })

    token
  end

  defp scan_body(overrides \\ %{}) do
    Map.merge(
      %{
        "commit_sha" => random_commit_sha(),
        "model" => "claude-sonnet-5",
        "prompt_version" => "tarakan-baseline/v1",
        "run_id" => "api-run-#{System.unique_integer([:positive, :monotonic])}",
        "document" => %{"tarakan_scan_format" => 1, "findings" => []}
      },
      overrides
    )
  end

  test "rejects requests without a token", %{conn: conn} do
    conn = post(conn, ~p"/api/github.com/openai/codex/reports", scan_body())

    assert json_response(conn, 401)["error"] =~ "API token"
  end

  test "rejects requests with an invalid or revoked token", %{conn: conn, account: account} do
    conn1 =
      conn |> authed("garbage") |> post(~p"/api/github.com/openai/codex/reports", scan_body())

    assert json_response(conn1, 401)

    old_token = api_token(account)
    [credential | _rest] = ApiCredentials.list(account)
    {:ok, _credential} = ApiCredentials.revoke(account, credential.id)

    conn2 =
      conn |> authed(old_token) |> post(~p"/api/github.com/openai/codex/reports", scan_body())

    assert json_response(conn2, 401)
  end

  test "404s for a repository not in the registry", %{conn: conn, token: token} do
    conn = conn |> authed(token) |> post(~p"/api/github.com/unknown/repo/reports", scan_body())

    assert json_response(conn, 404)["error"] =~ "not registered"
  end

  test "does not disclose a quarantined repository to an unrelated credential", %{
    conn: conn,
    repository: repository
  } do
    _contained =
      repository
      |> Repository.listing_changeset(%{listing_status: "quarantined"})
      |> Repo.update!()

    outsider_token = api_token(account_fixture())

    conn =
      conn
      |> authed(outsider_token)
      |> post(~p"/api/github.com/openai/codex/reports", scan_body())

    assert json_response(conn, 404)["error"] =~ "not registered"
  end

  test "records a clean scan", %{conn: conn, token: token} do
    conn = conn |> authed(token) |> post(~p"/api/github.com/openai/codex/reports", scan_body())

    response = json_response(conn, 201)
    assert response["findings_count"] == 0
    assert response["verified"] == false
    assert response["review_status"] == "quarantined"
    assert response["visibility"] == "public"
    assert response["provenance_attestation"] == "self_reported"
    assert response["repository"] == "openai/codex"
    assert response["record_url"] =~ "/github.com/openai/codex"

    repository = Repositories.get_github_repository("openai", "codex")
    assert repository.status == "reviewed"
    assert repository.scan_count == 1
  end

  test "records a scan with findings", %{conn: conn, token: token} do
    document = Jason.decode!(findings_json_fixture(2))
    body = scan_body(%{"document" => document, "notes" => "run #7 of the nightly sweep"})

    conn = conn |> authed(token) |> post(~p"/api/github.com/openai/codex/reports", body)

    response = json_response(conn, 201)
    assert response["findings_count"] == 2
    assert response["kind"] == "report"
    assert response["disclosed"] == true
    assert is_list(response["findings"])
    assert length(response["findings"]) == 2
    assert hd(response["findings"])["url"] =~ "/findings/"

    repository = Repositories.get_github_repository("openai", "codex")
    assert repository.status == "findings"
    assert repository.open_findings_count == 2
  end

  test "mass report path works without a job claim", %{conn: conn, token: token} do
    document = Jason.decode!(findings_json_fixture(1))
    body = scan_body(%{"document" => document, "provenance" => "agent"})

    conn =
      conn
      |> authed(token)
      |> post(~p"/api/github.com/openai/codex/reports", body)

    response = json_response(conn, 201)
    assert response["kind"] == "report"
    assert response["visibility"] == "public"
    assert response["findings_count"] == 1
    assert hd(response["findings"])["public_id"]
  end

  test "cannot self-accept or self-publish through submission attributes", %{
    conn: conn,
    token: token
  } do
    body =
      scan_body(%{
        "review_status" => "accepted",
        "visibility" => "public",
        "verified_at" => DateTime.utc_now()
      })

    conn = conn |> authed(token) |> post(~p"/api/github.com/openai/codex/reports", body)

    response = json_response(conn, 201)
    assert response["review_status"] == "quarantined"
    assert response["visibility"] == "public"
    assert response["verified"] == false
  end

  test "records a human-authored review without model metadata", %{conn: conn, token: token} do
    body = %{
      "commit_sha" => random_commit_sha(),
      "provenance" => "human",
      "review_kind" => "business_logic",
      "notes" => "Manually traced organization ownership transfer.",
      "document" => Jason.decode!(findings_json_fixture(1))
    }

    conn = conn |> authed(token) |> post(~p"/api/github.com/openai/codex/reports", body)

    response = json_response(conn, 201)
    assert response["provenance"] == "human"
    assert response["review_kind"] == "business_logic"
    assert response["model"] == nil
    assert response["prompt_version"] == nil
    assert response["findings_count"] == 1
  end

  test "requires the scan document", %{conn: conn, token: token} do
    body = Map.delete(scan_body(), "document")
    conn1 = conn |> authed(token) |> post(~p"/api/github.com/openai/codex/reports", body)
    assert %{"document" => [message]} = json_response(conn1, 422)["errors"]
    assert message =~ "required"

    conn2 =
      conn
      |> authed(token)
      |> post(~p"/api/github.com/openai/codex/reports", scan_body(%{"document" => "[]"}))

    assert json_response(conn2, 422)["errors"]["document"]
  end

  test "rejects an invalid document with the parser's message", %{conn: conn, token: token} do
    body = scan_body(%{"document" => %{"tarakan_scan_format" => 2, "findings" => []}})
    conn = conn |> authed(token) |> post(~p"/api/github.com/openai/codex/reports", body)

    assert %{"findings_json" => [message]} = json_response(conn, 422)["errors"]
    assert message == "tarakan_scan_format must be 1"
  end

  test "rejects envelope validation errors", %{conn: conn, token: token} do
    body = scan_body(%{"commit_sha" => "abc123", "model" => nil})
    conn = conn |> authed(token) |> post(~p"/api/github.com/openai/codex/reports", body)

    errors = json_response(conn, 422)["errors"]
    assert errors["commit_sha"] == ["must be a full 40-character commit SHA"]
    assert errors["model"] == ["can't be blank"]
  end

  test "rejects a commit GitHub does not know", %{conn: conn, token: token} do
    body = scan_body(%{"commit_sha" => "dead" <> String.duplicate("0", 36)})
    conn = conn |> authed(token) |> post(~p"/api/github.com/openai/codex/reports", body)

    assert json_response(conn, 422)["errors"]["commit_sha"] == [
             "commit not found in this repository on GitHub"
           ]
  end

  test "blocks retrying the same run id", %{conn: conn, token: token} do
    body = scan_body()

    conn1 = conn |> authed(token) |> post(~p"/api/github.com/openai/codex/reports", body)
    assert json_response(conn1, 201)

    conn2 = conn |> authed(token) |> post(~p"/api/github.com/openai/codex/reports", body)

    assert json_response(conn2, 422)["errors"]["run_id"] == [
             "this agent run was already submitted"
           ]
  end

  describe "GET /reports and verdict" do
    setup %{repository: repository, account: submitter} do
      scan =
        scan_fixture(repository, submitter, %{
          "findings_json" => findings_json_fixture(1)
        })

      reviewer = reviewer_tier_account_fixture()

      %{scan: scan, reviewer: reviewer, reviewer_token: reviews_token(reviewer)}
    end

    test "reviewer-tier reviews:read token sees restricted findings", %{
      conn: conn,
      reviewer_token: token,
      scan: scan
    } do
      scan = restrict_scan(scan)

      body =
        conn
        |> authed(token)
        |> get(~p"/api/github.com/openai/codex/reports")
        |> json_response(200)

      entry = Enum.find(body["reports"], &(&1["id"] == scan.id))
      assert entry["details_visible"]
      assert length(entry["findings"]) == 1
      assert hd(entry["findings"])["severity"]
    end

    test "returns compact canonical memory for reconciliation", %{
      conn: conn,
      token: token,
      scan: scan
    } do
      body =
        conn
        |> authed(token)
        |> get(~p"/api/github.com/openai/codex/memory?commit_sha=#{scan.commit_sha}")
        |> json_response(200)

      assert body["target_commit_sha"] == scan.commit_sha
      assert [finding] = body["findings"]
      assert finding["same_commit"]
      assert finding["status"] == "open"
      assert finding["detections_count"] == 1
      assert finding["public_id"]
    end

    test "records a check on one canonical finding", %{
      conn: conn,
      scan: scan
    } do
      token = reviews_token(moderator_account_fixture())

      memory =
        conn
        |> authed(token)
        |> get(~p"/api/github.com/openai/codex/memory?commit_sha=#{scan.commit_sha}")
        |> json_response(200)

      [finding] = memory["findings"]

      body =
        conn
        |> recycle()
        |> authed(token)
        |> post(~p"/api/github.com/openai/codex/findings/#{finding["public_id"]}/check", %{
          "commit_sha" => scan.commit_sha,
          "verdict" => "confirmed",
          "provenance" => "human",
          "notes" => "Independently reproduced this individual finding at the pinned commit."
        })
        |> json_response(201)

      assert body["status"] == "open"
      assert body["confirmations_count"] == 1
    end

    test "a plain findings:submit token cannot see restricted findings", %{
      conn: conn,
      token: token,
      scan: scan
    } do
      scan = restrict_scan(scan)

      body =
        conn
        |> authed(token)
        |> get(~p"/api/github.com/openai/codex/reports")
        |> json_response(200)

      # After a moderator takedown, the submitter's own restricted scan is not
      # exposed to a non-reviewer token.
      refute Enum.any?(body["reports"], &(&1["id"] == scan.id and &1["findings"] != []))
    end

    test "records a verdict with a proof-of-concept", %{
      conn: conn,
      reviewer_token: token,
      scan: scan
    } do
      body =
        conn
        |> authed(token)
        |> post(~p"/api/github.com/openai/codex/reports/#{scan.id}/check", %{
          "verdict" => "confirmed",
          "provenance" => "agent",
          "notes" => "Reproduced the reported issue against the pinned commit source.",
          "evidence" => "import test; test('repro', t => t.throws(() => vulnerable()))"
        })
        |> json_response(201)

      assert length(body["confirmations"]) == 1
      assert hd(body["confirmations"])["verdict"] == "confirmed"
    end

    test "the submitter cannot verify their own review", %{
      conn: conn,
      account: submitter,
      scan: scan
    } do
      token = reviews_token(reviewer_tier(submitter))

      conn =
        conn
        |> authed(token)
        |> post(~p"/api/github.com/openai/codex/reports/#{scan.id}/check", %{
          "verdict" => "confirmed",
          "notes" => "Trying to verify my own submission, which must be refused."
        })

      assert json_response(conn, 409)["error"] =~ "submitter"
    end

    test "a read-only reviewer credential cannot record a verdict", %{conn: conn, scan: scan} do
      # Reviewer-tier account (can see the scan) but the credential lacks
      # reviews:verify, so recording a verdict is forbidden.
      {:ok, read_only, _cred} =
        ApiCredentials.create(reviewer_tier_account_fixture(), %{
          name: "Read-only reviewer",
          scopes: ["reviews:read"]
        })

      conn =
        conn
        |> authed(read_only)
        |> post(~p"/api/github.com/openai/codex/reports/#{scan.id}/check", %{
          "verdict" => "confirmed",
          "notes" => "Has read access but no verify scope, so this must be denied."
        })

      assert json_response(conn, 403)["error"] =~ "not authorized"
    end

    test "a token that cannot see the review gets 404, not a leak", %{
      conn: conn,
      token: token,
      scan: scan
    } do
      scan = restrict_scan(scan)

      # A plain findings:submit token lacks read scope, so the restricted scan
      # is invisible - the endpoint must 404 rather than reveal it exists.
      conn =
        conn
        |> authed(token)
        |> post(~p"/api/github.com/openai/codex/reports/#{scan.id}/check", %{
          "verdict" => "confirmed",
          "notes" => "This token cannot see the scan, so it must not verify it."
        })

      assert json_response(conn, 404)["error"] =~ "not found"
    end
  end

  defp restrict_scan(scan) do
    moderator_scope = Scope.for_account(moderator_account_fixture())

    {:ok, scan} =
      Scans.update_visibility(moderator_scope, scan, "restricted", %{
        "moderation_reason" => "evidence_reviewed",
        "moderation_notes" => "Moderator takedown recorded for this visibility boundary test."
      })

    scan
  end

  defp reviewer_tier_account_fixture do
    account_fixture() |> reviewer_tier()
  end

  defp reviewer_tier(account) do
    account
    |> Tarakan.Accounts.Account.authorization_changeset(%{
      state: "active",
      platform_role: "member",
      trust_tier: "reviewer"
    })
    |> Repo.update!()
  end

  defp reviews_token(account) do
    {:ok, token, _credential} =
      ApiCredentials.create(account, %{
        name: "Verifier",
        scopes: ["reviews:read", "reviews:verify"]
      })

    token
  end
end
