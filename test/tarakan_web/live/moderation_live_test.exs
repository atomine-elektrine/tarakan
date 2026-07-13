defmodule TarakanWeb.ModerationLiveTest do
  use TarakanWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Tarakan.Accounts
  alias Tarakan.Accounts.Scope
  alias Tarakan.Moderation

  test "reporting requires an authenticated account", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/accounts/log-in"}}} =
             live(conn, ~p"/moderation/report")
  end

  test "a participant submits a restricted report and can inspect its case", %{conn: conn} do
    reporter = account_fixture()
    subject = account_fixture()
    conn = log_in_account(conn, reporter)

    {:ok, view, _html} =
      live(conn, ~p"/moderation/report?subject_type=account&subject_id=#{subject.id}")

    assert has_element?(view, "#moderation-report-form")
    assert has_element?(view, "#header-report-content")
    refute has_element?(view, "#header-moderation-queue")

    view
    |> form("#moderation-report-form",
      report: %{
        subject_type: "account",
        subject_id: subject.id,
        reason: "harassment",
        description: "This account is posting targeted harassment in public review evidence."
      }
    )
    |> render_submit()

    {path, flash} = assert_redirect(view)
    assert path =~ ~r{^/moderation/cases/\d+$}
    assert flash["info"]

    {:ok, case_view, _html} = live(conn, path)

    assert has_element?(case_view, "#moderation-case")
    assert has_element?(case_view, "#moderation-case-status", "Open")
    refute has_element?(case_view, "#moderation-case-actions")
    refute has_element?(case_view, "#moderation-case-assignment")
  end

  test "an ordinary account cannot open the moderator queue", %{conn: conn} do
    conn = log_in_account(conn, account_fixture())

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/moderation/queue")
  end

  test "a moderator assigns and resolves a queued report", %{conn: conn} do
    case_record = report_account!(account_fixture(), account_fixture())
    moderator = moderator_account_fixture()
    conn = log_in_account(conn, moderator)

    {:ok, queue_view, _html} = live(conn, ~p"/moderation/queue")

    assert has_element?(queue_view, "#header-moderation-queue")
    assert has_element?(queue_view, "#moderation-case-count", "1 open")
    assert has_element?(queue_view, "#assign-moderation-case-#{case_record.id}")

    queue_view
    |> element("#assign-moderation-case-#{case_record.id}")
    |> render_click()

    assert has_element?(queue_view, "#cases-#{case_record.id}", "In review")

    {:ok, case_view, _html} = live(conn, ~p"/moderation/cases/#{case_record.id}")
    assert has_element?(case_view, "#moderation-case-decision-form")

    case_view
    |> form("#moderation-case-decision-form",
      resolution: %{
        reason: "The evidence was independently reviewed and confirms a policy violation."
      }
    )
    |> render_submit(%{"disposition" => "resolved"})

    assert has_element?(case_view, "#moderation-case-status", "Resolved")
    assert has_element?(case_view, "#moderation-case-resolution")
    refute has_element?(case_view, "#moderation-case-decision-form")
  end

  test "the subject can appeal without receiving participant identity data", %{conn: conn} do
    reporter = account_fixture()
    subject = account_fixture()
    resolver = moderator_account_fixture()

    case_record =
      reporter
      |> report_account!(subject)
      |> resolve_case!(resolver, "resolved")

    conn = log_in_account(conn, subject)
    {:ok, view, _html} = live(conn, ~p"/moderation/cases/#{case_record.id}")

    assert has_element?(view, "#moderation-appeal-form")
    refute has_element?(view, "#moderation-case-actions")

    view
    |> form("#moderation-appeal-form",
      appeal: %{
        reason: "The decision cites evidence from a different account and should be reconsidered."
      }
    )
    |> render_submit()

    assert has_element?(view, "#moderation-case-appeals")
    assert has_element?(view, "#moderation-case-appeals", "Open")
    refute has_element?(view, "#moderation-appeal-form")
    refute has_element?(view, "#moderation-case-actions")
  end

  test "an independent moderator decides an appeal", %{conn: conn} do
    reporter = account_fixture()
    subject = account_fixture()
    resolver = moderator_account_fixture()
    appeal_moderator = moderator_account_fixture()

    case_record =
      reporter
      |> report_account!(subject)
      |> resolve_case!(resolver, "resolved")

    {:ok, appeal} =
      Moderation.appeal(Accounts.scope_for_account(subject), case_record, %{
        "reason" =>
          "The original decision relied on unrelated evidence and needs independent review."
      })

    conn = log_in_account(conn, appeal_moderator)
    {:ok, view, _html} = live(conn, ~p"/moderation/cases/#{case_record.id}")

    assert has_element?(view, "#moderation-appeal-decision-form-#{appeal.id}")

    view
    |> form("#moderation-appeal-decision-form-#{appeal.id}",
      appeal_decision: %{
        appeal_id: appeal.id,
        reason: "Independent review confirms the original evidence was unrelated."
      }
    )
    |> render_submit(%{"decision" => "upheld"})

    assert has_element?(view, "#moderation-case-status", "Overturned")
    assert has_element?(view, "#moderation-appeal-#{appeal.id}", "Upheld")
    refute has_element?(view, "#moderation-appeal-decision-form-#{appeal.id}")
  end

  defp report_account!(reporter, subject) do
    {:ok, case_record} =
      Moderation.report(Scope.for_account(reporter), %{
        "subject_type" => "account",
        "subject_id" => subject.id,
        "reason" => "fabricated_evidence",
        "description" => "The submitted evidence appears fabricated and needs independent review."
      })

    case_record
  end

  defp resolve_case!(case_record, moderator, disposition) do
    {:ok, assigned} = Moderation.assign(Scope.for_account(moderator), case_record)

    {:ok, decided} =
      Moderation.resolve(
        Scope.for_account(moderator),
        assigned,
        disposition,
        "The evidence was independently reviewed and supports this moderation decision."
      )

    decided
  end
end
