defmodule Tarakan.Policy do
  @moduledoc """
  The central, deny-by-default authorization policy.

  Contexts call `authorize/3` before performing state changes. The policy uses
  the account standing copied into the scope, explicit platform roles,
  verified repository relationships, and optional credential grants. Unknown
  actions are always denied.
  """

  alias Tarakan.Accounts.Scope
  alias Tarakan.Repositories.Repository

  @public_actions ~w(
    view_public_repository
    view_public_review
    view_public_task
  )a

  @mutation_actions ~w(
    register_repository
    push_repository
    manage_repository
    manage_repository_memberships
    propose_repository_membership
    verify_repository_membership
    change_account_authorization
    submit_review
    verify_review
    moderate_review
    propose_task
    publish_task
    disclose_task
    claim_task
    submit_contribution
    review_contribution
    cancel_task
    report_content
    appeal_moderation
    post_comment
    moderate_comment
    post_shout
    moderate_shout
    cast_vote
    moderate
    administer
  )a

  @restricted_read_actions ~w(
    view_restricted_review
    view_restricted_task
    view_audit_event
    clone_repository
  )a

  @known_actions @public_actions ++ @mutation_actions ++ @restricted_read_actions

  @credential_grants %{
    clone_repository: ~w(repo:read repo:write),
    push_repository: ~w(repo:write),
    register_repository: ~w(repositories:write),
    manage_repository: ~w(repositories:write),
    manage_repository_memberships: ~w(repositories:memberships),
    propose_repository_membership: ~w(repositories:memberships),
    verify_repository_membership: ~w(repositories:memberships),
    change_account_authorization: ~w(accounts:admin),
    submit_review: ~w(findings:submit reviews:submit),
    verify_review: ~w(findings:verify reviews:verify),
    moderate_review: ~w(moderation:write),
    view_restricted_review: ~w(findings:read reviews:read),
    propose_task: ~w(tasks:write),
    publish_task: ~w(tasks:write),
    disclose_task: ~w(tasks:write),
    claim_task: ~w(tasks:claim requests:claim),
    submit_contribution: ~w(contributions:write),
    review_contribution: ~w(contributions:review),
    cancel_task: ~w(tasks:write),
    report_content: ~w(reports:write),
    appeal_moderation: ~w(reports:write),
    post_comment: ~w(discussion:write),
    post_shout: ~w(discussion:write),
    cast_vote: ~w(discussion:write),
    moderate_comment: ~w(moderation:write),
    moderate_shout: ~w(moderation:write),
    view_restricted_task: ~w(tasks:read requests:read),
    view_audit_event: ~w(audit:read),
    moderate: ~w(moderation:write),
    administer: ~w(admin:write)
  }

  @pause_sensitive_actions ~w(
    push_repository
    submit_review
    verify_review
    moderate_review
    propose_task
    publish_task
    disclose_task
    claim_task
    submit_contribution
    review_contribution
    post_comment
    post_shout
  )a

  @doc """
  Authorizes `action` against `subject`.

  Returns `:ok` or the deliberately non-specific
  `{:error, :unauthorized}`. Callers should not reveal which part of an
  authorization decision failed.
  """
  def authorize(scope, action, subject \\ nil)

  def authorize(_scope, action, _subject) when action not in @known_actions,
    do: {:error, :unauthorized}

  def authorize(_scope, action, _subject) when action in @public_actions, do: :ok

  # Anyone - including anonymous git clients - may clone a publicly listed
  # repository. Unlisted repositories fall through to the authenticated path.
  def authorize(_scope, :clone_repository, %Repository{listing_status: "listed"}), do: :ok

  def authorize(%Scope{authentication_method: :system}, action, _subject)
      when action in @known_actions,
      do: :ok

  def authorize(%Scope{} = scope, action, subject) do
    if authenticated?(scope) and
         standing_allows?(scope, action) and
         credential_allows?(scope, action, subject) and
         repository_mode_allows?(scope, action, subject) and
         action_allowed?(scope, action, subject) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  def authorize(_scope, _action, _subject), do: {:error, :unauthorized}

  @doc "Boolean form of `authorize/3`."
  def allowed?(scope, action, subject \\ nil) do
    authorize(scope, action, subject) == :ok
  end

  @doc "Whether the scope belongs to a platform moderator or administrator."
  def moderator?(%Scope{platform_role: role}) when role in ["moderator", "admin"], do: true
  def moderator?(_scope), do: false

  @doc "Whether the scope belongs to a platform administrator."
  def admin?(%Scope{platform_role: "admin"}), do: true
  def admin?(_scope), do: false

  @doc "Whether the scope has a verified steward relationship."
  def repository_steward?(scope, subject) do
    Scope.repository_role?(scope, repository_id(subject), "steward")
  end

  @doc "Whether the scope has a verified reviewer or steward relationship."
  def repository_reviewer?(scope, subject) do
    Scope.repository_role?(scope, repository_id(subject), ["reviewer", "steward"])
  end

  @doc "Whether account standing permits ordinary state changes."
  def mutation_allowed?(%Scope{account_state: state}) when state in ["probation", "active"],
    do: true

  def mutation_allowed?(_scope), do: false

  @doc "Credential grants accepted for an action."
  def required_token_scopes(action), do: Map.get(@credential_grants, action, [])

  defp authenticated?(%Scope{account_id: account_id}) when is_integer(account_id), do: true
  defp authenticated?(_scope), do: false

  defp standing_allows?(%Scope{account_state: state}, action)
       when action in [:report_content, :appeal_moderation],
       do: state not in ["suspended", "banned"]

  defp standing_allows?(scope, action) when action in @mutation_actions,
    do: mutation_allowed?(scope)

  defp standing_allows?(%Scope{account_state: state}, _action),
    do: state not in ["suspended", "banned"]

  defp credential_allows?(%Scope{} = scope, action, subject) do
    credential_scope_allows?(scope, action) and credential_repository_allows?(scope, subject)
  end

  defp credential_scope_allows?(scope, action) do
    case required_token_scopes(action) do
      [] -> true
      grants -> Scope.token_scope?(scope, grants)
    end
  end

  defp credential_repository_allows?(%Scope{token_repository_id: nil}, _subject), do: true

  defp credential_repository_allows?(%Scope{token_repository_id: token_repository_id}, subject) do
    repository_id(subject) == token_repository_id
  end

  defp repository_mode_allows?(scope, action, subject)
       when action in @pause_sensitive_actions do
    not repository_paused?(subject) or moderator?(scope)
  end

  defp repository_mode_allows?(_scope, _action, _subject), do: true

  defp action_allowed?(_scope, :register_repository, _subject), do: true
  defp action_allowed?(_scope, :submit_review, _subject), do: true
  defp action_allowed?(_scope, :propose_task, _subject), do: true
  defp action_allowed?(_scope, :claim_task, _subject), do: true
  defp action_allowed?(_scope, :submit_contribution, _subject), do: true
  defp action_allowed?(_scope, :propose_repository_membership, _subject), do: true
  defp action_allowed?(_scope, :report_content, _subject), do: true
  defp action_allowed?(_scope, :appeal_moderation, _subject), do: true

  # Any account in good standing may join the discussion; standing_allows?/2
  # already excludes suspended and banned accounts.
  defp action_allowed?(_scope, :post_comment, _subject), do: true
  defp action_allowed?(_scope, :post_shout, _subject), do: true
  defp action_allowed?(_scope, :cast_vote, _subject), do: true

  defp action_allowed?(scope, :moderate_comment, subject),
    do: moderator?(scope) or repository_steward?(scope, subject)

  defp action_allowed?(scope, :moderate_shout, _subject), do: moderator?(scope)

  defp action_allowed?(scope, :verify_review, subject),
    do: platform_reviewer?(scope) or qualified_reviewer?(scope, subject)

  defp action_allowed?(scope, :moderate_review, subject),
    do: moderator?(scope) or repository_steward?(scope, subject)

  defp action_allowed?(scope, :view_restricted_review, subject),
    do:
      owns_subject?(scope, subject) or platform_reviewer?(scope) or
        qualified_reviewer?(scope, subject)

  defp action_allowed?(scope, :publish_task, subject),
    do: moderator?(scope) or repository_steward?(scope, subject)

  defp action_allowed?(scope, :disclose_task, subject),
    do: moderator?(scope) or repository_steward?(scope, subject)

  defp action_allowed?(scope, :review_contribution, subject),
    do: qualified_reviewer?(scope, subject)

  defp action_allowed?(scope, :cancel_task, subject),
    do: owns_subject?(scope, subject) or moderator?(scope) or repository_steward?(scope, subject)

  defp action_allowed?(scope, :view_restricted_task, subject),
    do: owns_subject?(scope, subject) or qualified_reviewer?(scope, subject)

  defp action_allowed?(scope, :clone_repository, subject),
    do: moderator?(scope) or repository_reviewer?(scope, subject)

  defp action_allowed?(scope, :push_repository, subject),
    do: moderator?(scope) or repository_steward?(scope, subject)

  defp action_allowed?(scope, :manage_repository, subject),
    do: moderator?(scope) or repository_steward?(scope, subject)

  defp action_allowed?(scope, :manage_repository_memberships, subject),
    do: moderator?(scope) or repository_steward?(scope, subject)

  defp action_allowed?(scope, :verify_repository_membership, subject),
    do: moderator?(scope) or repository_steward?(scope, subject)

  defp action_allowed?(scope, :change_account_authorization, _subject), do: admin?(scope)

  defp action_allowed?(scope, :view_audit_event, subject),
    do: moderator?(scope) or repository_steward?(scope, subject)

  defp action_allowed?(scope, :moderate, _subject), do: moderator?(scope)
  defp action_allowed?(scope, :administer, _subject), do: admin?(scope)

  defp qualified_reviewer?(scope, subject),
    do: moderator?(scope) or repository_reviewer?(scope, subject)

  # A platform-trusted reviewer may verify reviews (and read restricted review
  # evidence) across repositories - but NOT contribution review or restricted
  # tasks, which remain per-repo grants. Independence is preserved by the
  # not-the-submitter conflict check enforced at the call site.
  defp platform_reviewer?(%Scope{trust_tier: "reviewer"}), do: true
  defp platform_reviewer?(_scope), do: false

  defp owns_subject?(%Scope{account_id: account_id}, subject) when is_integer(account_id) do
    owner_ids =
      ~w(account_id author_id claimant_id claimed_by_id contributor_id created_by_id creator_id submitted_by_id)a
      |> Enum.map(&field(subject, &1))

    account_id in owner_ids
  end

  defp owns_subject?(_scope, _subject), do: false

  defp repository_paused?(%Repository{participation_mode: "paused"}), do: true
  defp repository_paused?(subject), do: repository_mode(subject) == "paused"

  defp repository_mode(subject) do
    field(subject, :participation_mode) ||
      subject |> field(:repository) |> field(:participation_mode) ||
      subject |> field(:task) |> field(:repository) |> field(:participation_mode) ||
      subject |> field(:review_task) |> field(:repository) |> field(:participation_mode)
  end

  defp repository_id(%Repository{id: repository_id}), do: repository_id
  defp repository_id(nil), do: nil

  defp repository_id(subject) do
    field(subject, :repository_id) ||
      subject |> field(:repository) |> field(:id) ||
      subject |> field(:task) |> repository_id() ||
      subject |> field(:review_task) |> repository_id()
  end

  defp field(nil, _key), do: nil

  defp field(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, to_string(key))

  defp field(_value, _key), do: nil
end
