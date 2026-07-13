defmodule Tarakan.Repo.Migrations.HashExistingSessionTokens do
  use Ecto.Migration
  import Ecto.Query

  # Session tokens moved from raw storage to SHA-256 hashes (matching how email
  # and magic-link tokens were always stored). Convert existing "session" rows
  # in place so live sessions and remember-me cookies survive the deploy instead
  # of being silently logged out — and so the old raw rows don't linger
  # undeletable (logout now deletes by hash and would never match them).
  #
  # Safe because migrations run before the new app boots: every "session" row
  # present here was written by the old code and still holds a raw token.
  def up do
    from(t in "accounts_tokens", where: t.context == "session", select: {t.id, t.token})
    |> repo().all()
    |> Enum.each(fn {id, token} when is_binary(token) ->
      hashed = :crypto.hash(:sha256, token)
      repo().update_all(from(t in "accounts_tokens", where: t.id == ^id), set: [token: hashed])
    end)
  end

  # Hashing is one-way; raw tokens cannot be restored.
  def down, do: :ok
end
