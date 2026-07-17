defmodule TarakanWeb.JobsLiveTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tarakan.WorkFixtures

  test "renders the public jobs queue for anonymous visitors", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/jobs")

    assert html =~ "Open jobs"
    assert html =~ "tarakan login"
    assert html =~ "tarakan --agent codex --pickup"
  end

  test "/requests alias lands on the same queue", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/requests")
    assert html =~ "Open jobs"
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
end
