defmodule TarakanWeb.ChangesetErrors do
  @moduledoc """
  Renders an Ecto changeset's errors into a plain, JSON-encodable map for API
  responses (field => list of interpolated messages).
  """

  @doc "Traverses `changeset` errors, interpolating `%{count}`-style placeholders."
  def to_map(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
