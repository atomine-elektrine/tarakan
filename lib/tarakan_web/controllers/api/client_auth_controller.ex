defmodule TarakanWeb.API.ClientAuthController do
  use TarakanWeb, :controller

  alias Tarakan.Accounts.{ApiCredentials, ClientAuthorizations}
  alias TarakanWeb.BrowserRateLimit
  alias TarakanWeb.Plugs.ClientIp

  @doc "Starts a short-lived browser login for Tarakan Client."
  def start(conn, params) do
    if BrowserRateLimit.allowed?(:client_auth_start_ip, ClientIp.remote_ip_string(conn)) do
      attrs = %{"client_name" => params["client_name"] || "Tarakan Client"}

      case ClientAuthorizations.start(attrs) do
        {:ok, device_code, user_code, authorization} ->
          path = ~p"/client/authorize/#{user_code}"

          conn
          |> no_store()
          |> put_status(:created)
          |> json(%{
            device_code: device_code,
            user_code: user_code,
            verification_uri: TarakanWeb.Endpoint.url() <> path,
            verification_uri_complete: TarakanWeb.Endpoint.url() <> path,
            expires_in: DateTime.diff(authorization.expires_at, DateTime.utc_now(), :second),
            interval: ClientAuthorizations.poll_interval_seconds()
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> no_store()
          |> put_status(:unprocessable_entity)
          |> json(%{error: "invalid_client", details: changeset_errors(changeset)})
      end
    else
      rate_limited(conn)
    end
  end

  @doc "Exchanges an approved device code for a scoped API credential exactly once."
  def exchange(conn, %{"device_code" => device_code}) do
    if BrowserRateLimit.allowed?(:client_auth_exchange_ip, ClientIp.remote_ip_string(conn)) do
      case ClientAuthorizations.exchange(device_code) do
        {:ok, {token, credential}} ->
          conn
          |> no_store()
          |> json(%{
            token: token,
            token_type: "Bearer",
            expires_at: credential.expires_at,
            scopes: credential.scopes
          })

        {:error, :authorization_pending} ->
          conn
          |> no_store()
          |> put_status(:bad_request)
          |> json(%{error: "authorization_pending"})

        {:error, :access_denied} ->
          conn |> no_store() |> put_status(:forbidden) |> json(%{error: "access_denied"})

        {:error, :account_locked} ->
          conn |> no_store() |> put_status(:forbidden) |> json(%{error: "access_denied"})

        {:error, :expired} ->
          conn |> no_store() |> put_status(:gone) |> json(%{error: "expired_token"})

        {:error, :credential_limit} ->
          conn
          |> no_store()
          |> put_status(:conflict)
          |> json(%{error: "credential_limit"})

        {:error, _reason} ->
          conn |> no_store() |> put_status(:bad_request) |> json(%{error: "invalid_device_code"})
      end
    else
      rate_limited(conn)
    end
  end

  def exchange(conn, _params) do
    conn |> no_store() |> put_status(:bad_request) |> json(%{error: "invalid_device_code"})
  end

  @doc "Revokes the API credential making this request."
  def revoke(conn, _params) do
    scope = conn.assigns.current_scope

    case ApiCredentials.revoke(scope.account, scope.token_id) do
      {:ok, _credential} -> conn |> no_store() |> send_resp(:no_content, "")
      {:error, :not_found} -> conn |> no_store() |> send_resp(:no_content, "")
    end
  end

  defp rate_limited(conn) do
    conn
    |> no_store()
    |> put_resp_header("retry-after", "60")
    |> put_status(:too_many_requests)
    |> json(%{error: "rate_limit_exceeded"})
  end

  defp no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")

  defp changeset_errors(changeset), do: TarakanWeb.ChangesetErrors.to_map(changeset)
end
