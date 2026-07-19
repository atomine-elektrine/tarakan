defmodule TarakanWeb.JobsLiveTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tarakan.WorkFixtures

  test "renders the public jobs queue for anonymous visitors", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/jobs")

    assert html =~ "Jobs"
    assert html =~ "tarakan login"
    assert html =~ "tarakan --agent codex --pickup"
    assert html =~ "tarakan worker --agent codex"
  end

  test "lists open public jobs", %{conn: conn} do
    submitter = account_fixture()
    repository = listed_github_repository_fixture(submitter)

    task =
      review_task_fixture(repository, submitter, %{
        "title" => "Review auth middleware",
        "visibility" => "public"
      })

    {:ok, view, html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#job-#{task.id}")
    assert html =~ "Review auth middleware"
  end

  test "check jobs surface before ordinary open jobs", %{conn: conn} do
    submitter = account_fixture()
    repository = listed_github_repository_fixture(submitter)

    ordinary =
      review_task_fixture(repository, submitter, %{
        "title" => "Ordinary code review job",
        "kind" => "code_review",
        "visibility" => "public"
      })

    # Publishing a Report with findings auto-opens a verify_findings Job.
    _scan =
      scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})

    check =
      Tarakan.Work.list_open_public_tasks(20)
      |> Enum.find(&(&1.kind == "verify_findings" and &1.repository_id == repository.id))

    assert check

    {:ok, _view, html} = live(conn, ~p"/jobs")

    check_pos = :binary.match(html, "job-#{check.id}") |> elem(0)
    ordinary_pos = :binary.match(html, "job-#{ordinary.id}") |> elem(0)
    assert check_pos < ordinary_pos
  end
end
