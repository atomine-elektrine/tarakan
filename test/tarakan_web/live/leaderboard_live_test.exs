defmodule TarakanWeb.LeaderboardLiveTest do
  use TarakanWeb.ConnCase

  import Phoenix.LiveViewTest

  defp verified_contributor do
    submitter = github_account_fixture()
    repository = listed_github_repository_fixture(submitter)
    scan = scan_fixture(repository, submitter, %{"findings_json" => findings_json_fixture(1)})
    confirmation_fixture(scan, reviewer_account_fixture())
    confirmation_fixture(scan, reviewer_account_fixture())
    submitter
  end

  test "renders ranked contributors linking to their profiles", %{conn: conn} do
    submitter = verified_contributor()

    {:ok, view, _html} = live(conn, ~p"/leaderboard")

    assert has_element?(view, "#leaderboard-rank-1")
    assert has_element?(view, ~s(#leaderboard a[href="/#{submitter.handle}"]))
    # The distinct verified canonical finding (+30) puts the submitter on top;
    # the report occurrence itself is not a second reputation event.
    assert has_element?(view, "#leaderboard-rank-1", submitter.handle)
    assert has_element?(view, "#leaderboard-rank-1", "30")
  end

  test "the leaderboard can be re-sorted", %{conn: conn} do
    verified_contributor()
    {:ok, view, _html} = live(conn, ~p"/leaderboard")

    html = view |> element("#leaderboard-sort button[phx-value-by='findings']") |> render_click()
    assert html =~ ~s(aria-pressed="true")
  end

  test "an empty record shows the empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/leaderboard")
    assert has_element?(view, "#leaderboard-empty")
  end

  test "the header links to the leaderboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ~s(a[href="/leaderboard"]))
  end
end
