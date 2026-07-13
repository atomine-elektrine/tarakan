defmodule Tarakan.Requests do
  @moduledoc """
  Canonical product language for optional security **Requests** (work queue).

  Requests are today's ReviewTasks: claimable coordination items. Completing a
  finding-kind Request with a Review Format document creates a linked Review.
  This module façades `Tarakan.Work`.
  """

  alias Tarakan.Work

  defdelegate subscribe(repository_id), to: Work
  defdelegate broadcast_refresh(task), to: Work
  defdelegate broadcast_repository_refresh(repository_id), to: Work
  defdelegate kinds(), to: Work
  defdelegate capabilities(), to: Work
  defdelegate provenances(), to: Work

  def list_tasks(repository), do: Work.list_tasks(repository)
  def list_tasks(repository, opts), do: Work.list_tasks(repository, opts)
  def list_open_public_tasks(), do: Work.list_open_public_tasks()
  def list_open_public_tasks(limit), do: Work.list_open_public_tasks(limit)

  defdelegate get_task!(id), to: Work
  defdelegate get_task(id), to: Work
  def get_visible_task(id), do: Work.get_visible_task(id)
  def get_visible_task(id, scope), do: Work.get_visible_task(id, scope)

  def change_task(), do: Work.change_task()
  def change_task(task), do: Work.change_task(task)
  def change_task(task, attrs), do: Work.change_task(task, attrs)
  def change_contribution(), do: Work.change_contribution()
  def change_contribution(contribution), do: Work.change_contribution(contribution)
  def change_contribution(contribution, attrs), do: Work.change_contribution(contribution, attrs)

  defdelegate create_task(repository, creator, attrs), to: Work
  defdelegate publish_task(task, actor, attrs), to: Work
  defdelegate claim_task(task, actor), to: Work
  defdelegate release_task(task, actor), to: Work
  defdelegate renew_claim(task, actor), to: Work
  defdelegate submit_task(task, actor, attrs), to: Work
  defdelegate complete_task(task, actor, attrs), to: Work
  defdelegate accept_task(task, actor, attrs), to: Work
  defdelegate request_changes(task, actor, attrs), to: Work
  defdelegate reject_task(task, actor, attrs), to: Work
  defdelegate cancel_task(task, actor, attrs), to: Work
  defdelegate disclose_task(task, actor, visibility, attrs), to: Work

  def list_requests(repository), do: list_tasks(repository)
  def list_requests(repository, opts), do: list_tasks(repository, opts)
  def get_request!(id), do: get_task!(id)
  def get_request(id), do: get_task(id)
  def get_visible_request(id), do: get_visible_task(id)
  def get_visible_request(id, scope), do: get_visible_task(id, scope)
  def create_request(repository, creator, attrs), do: create_task(repository, creator, attrs)
  def claim_request(task, actor), do: claim_task(task, actor)
  def release_request(task, actor), do: release_task(task, actor)
  def renew_request_claim(task, actor), do: renew_claim(task, actor)
  def submit_request(task, actor, attrs), do: submit_task(task, actor, attrs)
  def complete_request(task, actor, attrs), do: complete_task(task, actor, attrs)
end
