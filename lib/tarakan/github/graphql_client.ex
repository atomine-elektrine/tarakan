defmodule Tarakan.GitHub.GraphQLClient do
  @moduledoc false

  @behaviour Tarakan.GitHubBulkClient

  @endpoint "https://api.github.com/graphql"
  @max_response_bytes 2 * 1_024 * 1_024

  @query """
  query($ids: [ID!]!) {
    nodes(ids: $ids) {
      ... on Repository {
        id
        databaseId
        name
        url
        isPrivate
        isArchived
        description
        stargazerCount
        forkCount
        owner { login }
        defaultBranchRef { name }
        primaryLanguage { name }
      }
    }
  }
  """

  @impl true
  def fetch_repositories_by_node_ids(node_ids)
      when is_list(node_ids) and length(node_ids) <= 100 do
    with {:ok, token} <- api_token(),
         {:ok, body} <- post_query(token, node_ids),
         {:ok, nodes} <- extract_nodes(body, length(node_ids)) do
      {:ok, Enum.map(nodes, &node_metadata/1)}
    end
  end

  def fetch_repositories_by_node_ids(_node_ids), do: {:error, :invalid_response}

  defp api_token do
    case Application.fetch_env!(:tarakan, :github)[:api_token] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _missing -> {:error, :no_token}
    end
  end

  defp post_query(token, node_ids) do
    request =
      Req.post(@endpoint,
        json: %{query: @query, variables: %{ids: node_ids}},
        headers: [
          {"authorization", "Bearer #{token}"},
          {"user-agent", "Tarakan/0.1 (https://tarakan.lol)"}
        ],
        retry: false,
        receive_timeout: 30_000
      )

    case request do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        if :erlang.external_size(body) <= @max_response_bytes,
          do: {:ok, body},
          else: {:error, :invalid_response}

      {:ok, %{status: status}} when status in [403, 429] ->
        {:error, :rate_limited}

      {:ok, _response} ->
        {:error, :unavailable}

      {:error, _exception} ->
        {:error, :unavailable}
    end
  end

  defp extract_nodes(%{"errors" => errors} = body, expected)
       when is_list(errors) and errors != [] do
    # GraphQL reports missing/forbidden nodes as errors alongside partial
    # data; RATE_LIMITED is the only error class that should abort the batch.
    if Enum.any?(errors, &(&1["type"] == "RATE_LIMITED")) do
      {:error, :rate_limited}
    else
      extract_nodes(Map.delete(body, "errors"), expected)
    end
  end

  defp extract_nodes(body, expected) do
    case get_in(body, ["data", "nodes"]) do
      nodes when is_list(nodes) and length(nodes) == expected -> {:ok, nodes}
      _other -> {:error, :invalid_response}
    end
  end

  # A node that no longer resolves (deleted, or hidden from this token).
  defp node_metadata(nil), do: nil
  defp node_metadata(node) when node == %{}, do: nil

  defp node_metadata(%{"isPrivate" => true}), do: :not_public

  defp node_metadata(%{"databaseId" => database_id, "id" => node_id} = node)
       when is_integer(database_id) and is_binary(node_id) do
    %{
      github_id: database_id,
      node_id: node_id,
      host: "github.com",
      owner: get_in(node, ["owner", "login"]),
      name: node["name"],
      canonical_url: node["url"],
      default_branch: get_in(node, ["defaultBranchRef", "name"]),
      description: node["description"],
      primary_language: get_in(node, ["primaryLanguage", "name"]),
      stars_count: node["stargazerCount"] || 0,
      forks_count: node["forkCount"] || 0,
      archived: node["isArchived"] || false,
      private: false,
      visibility: "public",
      last_synced_at: DateTime.utc_now()
    }
  end

  defp node_metadata(_node), do: nil
end
