defmodule Tarakan.Discussion do
  @moduledoc """
  Threaded, public-at-creation discussion on findings.

  Discussion is a conversation layer that sits beside verification, never
  inside it: comments never affect a scan's quorum or a repository's status.
  Every comment is public the moment it is posted; the only way one leaves
  the record is a moderation takedown, which leaves a placeholder in place so
  the thread stays legible.

  Comment visibility follows the parent finding: if the caller can open the
  finding, they can read its discussion. Posting requires an account in good
  standing (`:post_comment`); taking a comment down requires a moderator or
  repository steward (`:moderate_comment`).
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Tarakan.Accounts.{Account, Scope}
  alias Tarakan.Audit
  alias Tarakan.Discussion.Comment
  alias Tarakan.Policy
  alias Tarakan.RateLimiter
  alias Tarakan.Repo
  alias Tarakan.Scans.Finding

  @topic_prefix "discussion:finding:"
  @rate_limit 20
  @rate_window_seconds 300

  @doc "Subscribes the caller to a finding's discussion events."
  def subscribe(finding_id) do
    Phoenix.PubSub.subscribe(Tarakan.PubSub, topic(finding_id))
  end

  @doc """
  Returns a finding's comments as an ordered forest of `%Comment{}` structs,
  each with `:depth` and nested `:replies` populated for rendering.

  Top-level threads are ranked by author authority, then oldest-first so an
  early substantive exchange reads top to bottom; replies within a thread are
  always chronological. Removed comments keep their place with the body
  stripped for anyone who cannot moderate them.
  """
  def list_comments(scope, %Finding{id: finding_id}) do
    comments =
      Comment
      |> where([comment], comment.finding_id == ^finding_id)
      |> order_by([comment], asc: comment.inserted_at, asc: comment.id)
      |> preload(:account)
      |> Repo.all()
      |> Enum.map(&redact_removed(&1, scope))

    build_forest(comments)
  end

  @doc """
  Posts a comment on `finding`. `parent_id`, when given, must be another
  comment on the same finding and not already at the maximum nesting depth.
  """
  def create_comment(%Scope{account: %Account{}} = scope, %Finding{} = finding, attrs) do
    parent_id = normalize_parent_id(attrs)

    Multi.new()
    |> Multi.run(:authorization, fn _repo, _changes ->
      if Policy.allowed?(scope, :post_comment, finding) and within_rate_limit?(scope),
        do: {:ok, scope},
        else: {:error, :unauthorized}
    end)
    |> Multi.run(:parent, fn repo, _changes -> resolve_parent(repo, finding, parent_id) end)
    |> Multi.insert(:comment, fn %{parent: parent} ->
      %Comment{
        finding_id: finding.id,
        repository_id: finding.scan.repository_id,
        account_id: scope.account.id,
        parent_id: parent && parent.id
      }
      |> Comment.changeset(attrs)
    end)
    |> Multi.insert(:audit, fn %{comment: comment} ->
      Audit.event_changeset(scope, :discussion_comment_posted, comment, %{
        metadata: %{finding_id: finding.id, parent_id: comment.parent_id}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{comment: comment}} ->
        comment = Repo.preload(comment, [:account, :repository])
        broadcast(finding.id, {:comment_posted, comment})
        Tarakan.Activity.broadcast_comment(comment, finding)
        {:ok, comment}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def create_comment(_scope, _finding, _attrs), do: {:error, :unauthorized}

  @doc "Takes a comment down. The row and its place in the thread remain."
  def remove_comment(%Scope{account: %Account{}} = scope, %Comment{} = comment, attrs) do
    Multi.new()
    |> Multi.run(:authorization, fn _repo, _changes ->
      if Policy.allowed?(scope, :moderate_comment, comment),
        do: {:ok, scope},
        else: {:error, :unauthorized}
    end)
    |> Multi.update(:comment, Comment.removal_changeset(comment, attrs, scope.account.id))
    |> Multi.insert(:audit, fn %{comment: removed} ->
      Audit.event_changeset(scope, :discussion_comment_removed, removed, %{
        reason_code: removed.removed_reason,
        metadata: %{finding_id: removed.finding_id}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{comment: removed}} ->
        removed = Repo.preload(removed, :account)
        broadcast(removed.finding_id, {:comment_removed, removed})
        {:ok, removed}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def remove_comment(_scope, _comment, _attrs), do: {:error, :unauthorized}

  @doc """
  Whether `scope` can take down comments on `finding` - a moderator or a
  steward of the finding's repository. Drives the moderation affordance and
  whether removed bodies are returned in `list_comments/2`.
  """
  def can_moderate?(%Scope{} = scope, %Finding{scan: %{repository_id: repository_id}}) do
    Policy.allowed?(scope, :moderate_comment, %Comment{repository_id: repository_id})
  end

  def can_moderate?(_scope, _finding), do: false

  @doc "Fetches a comment for moderation, with the data removal needs."
  def get_comment(id) do
    case Repo.get(Comment, id) do
      nil -> {:error, :not_found}
      comment -> {:ok, Repo.preload(comment, [:account, :repository])}
    end
  end

  # --- internals ---------------------------------------------------------

  defp build_forest(comments) do
    children = Enum.group_by(comments, & &1.parent_id)

    comments
    |> Enum.filter(&is_nil(&1.parent_id))
    |> rank_top_level()
    |> Enum.map(&attach_replies(&1, 0, children))
  end

  defp attach_replies(comment, depth, children) do
    replies =
      children
      |> Map.get(comment.id, [])
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
      |> Enum.map(&attach_replies(&1, depth + 1, children))

    %{comment | depth: depth, replies: replies}
  end

  # Author authority is the only quality signal available without votes:
  # moderators and platform reviewers surface first, then oldest-first.
  defp rank_top_level(comments) do
    Enum.sort_by(comments, &{authority_rank(&1.account), &1.inserted_at, &1.id})
  end

  defp authority_rank(%Account{platform_role: role}) when role in ["moderator", "admin"], do: 0
  defp authority_rank(%Account{trust_tier: "reviewer"}), do: 1
  defp authority_rank(%Account{trust_tier: "contributor"}), do: 2
  defp authority_rank(_account), do: 3

  defp redact_removed(%Comment{removed_at: nil} = comment, _scope), do: comment

  defp redact_removed(%Comment{} = comment, scope) do
    if Policy.allowed?(scope, :moderate_comment, comment) do
      comment
    else
      %{comment | body: nil}
    end
  end

  defp resolve_parent(_repo, _finding, nil), do: {:ok, nil}

  defp resolve_parent(repo, finding, parent_id) do
    case repo.get(Comment, parent_id) do
      %Comment{finding_id: finding_id} = parent when finding_id == finding.id ->
        if comment_depth(repo, parent) < Comment.max_depth(),
          do: {:ok, parent},
          else: {:error, :too_deep}

      _mismatch ->
        {:error, :invalid_parent}
    end
  end

  # Walks the ancestry to the current nesting depth. Chains are bounded by
  # @max_depth at creation, so this stays shallow.
  defp comment_depth(repo, comment, depth \\ 0)
  defp comment_depth(_repo, %Comment{parent_id: nil}, depth), do: depth

  defp comment_depth(repo, %Comment{parent_id: parent_id}, depth) do
    case repo.get(Comment, parent_id) do
      nil -> depth
      parent -> comment_depth(repo, parent, depth + 1)
    end
  end

  defp within_rate_limit?(%Scope{account: %Account{platform_role: role}})
       when role in ["moderator", "admin"],
       do: true

  defp within_rate_limit?(%Scope{account: %Account{id: account_id}}) do
    RateLimiter.check({:discussion_comment, account_id}, @rate_limit, @rate_window_seconds) == :ok
  end

  defp normalize_parent_id(attrs) do
    case attrs["parent_id"] || attrs[:parent_id] do
      nil -> nil
      "" -> nil
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
    end
  rescue
    ArgumentError -> nil
  end

  defp broadcast(finding_id, message) do
    Phoenix.PubSub.broadcast(Tarakan.PubSub, topic(finding_id), message)
  end

  defp topic(finding_id), do: @topic_prefix <> to_string(finding_id)
end
