defmodule TarakanWeb.AccountLive.Settings do
  use TarakanWeb, :live_view

  on_mount {TarakanWeb.AccountAuth, :require_sudo_mode}

  alias Tarakan.Accounts
  alias Tarakan.Accounts.{ApiCredential, ApiCredentials, SshKeys}
  alias Tarakan.Repositories
  alias TarakanWeb.AccountAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page width={:focused}>
        <div class="mx-auto max-w-3xl">
          <div class="text-center">
            <.header>
              Account settings
              <:subtitle>@{@current_scope.account.handle} · manage sign-in and recovery</:subtitle>
            </.header>
          </div>

          <section class="mt-6 border-2 border-strong bg-panel p-6">
            <h2 class="text-sm font-semibold text-ink">Connected code hosts</h2>
            <div class="mt-4 grid gap-3 sm:grid-cols-2">
              <.link
                id="settings-github-identity"
                href={~p"/auth/github?#{[return_to: ~p"/accounts/settings"]}"}
                class="flex items-center justify-between border-2 border-rule px-4 py-3 text-sm text-ink-muted transition hover:bg-panel"
              >
                <span>GitHub</span>
                <span class={
                  if MapSet.member?(@identity_providers, "github"),
                    do: "text-signal",
                    else: "text-ink-faint"
                }>
                  {if MapSet.member?(@identity_providers, "github"), do: "Connected", else: "Connect"}
                </span>
              </.link>
              <.link
                id="settings-gitlab-identity"
                href={~p"/auth/gitlab?#{[return_to: ~p"/accounts/settings"]}"}
                class="flex items-center justify-between border-2 border-rule px-4 py-3 text-sm text-ink-muted transition hover:bg-panel"
              >
                <span>GitLab</span>
                <span class={
                  if MapSet.member?(@identity_providers, "gitlab"),
                    do: "text-signal",
                    else: "text-ink-faint"
                }>
                  {if MapSet.member?(@identity_providers, "gitlab"), do: "Connected", else: "Connect"}
                </span>
              </.link>
            </div>
          </section>

          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
            class="mt-6 space-y-3 border-2 border-strong bg-panel p-6"
          >
            <h2 class="text-sm font-semibold text-ink">Email address</h2>
            <.input
              field={@email_form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.button variant="primary" phx-disable-with="Changing...">Save email</.button>
          </.form>

          <.form
            for={@password_form}
            id="password_form"
            action={~p"/accounts/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            class="mt-5 space-y-3 border-2 border-strong bg-panel p-6"
          >
            <h2 class="text-sm font-semibold text-ink">Password</h2>
            <p class="text-xs leading-5 text-ink-faint">
              At least 15 characters.
            </p>
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              spellcheck="false"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              spellcheck="false"
            />
            <.button variant="primary" phx-disable-with="Saving...">
              Save password
            </.button>
          </.form>

          <section id="api-token" class="mt-5 border-2 border-strong bg-panel p-6">
            <h2 class="text-sm font-semibold text-ink">Client credentials</h2>
            <p class="mt-1 text-xs leading-5 text-ink-faint">
              <span class="font-mono">TARAKAN_API_TOKEN</span>, sent as <span class="font-mono">Authorization: Bearer &lt;token&gt;</span>. Defaults expire after {ApiCredentials.default_validity_days()} days (max {ApiCredentials.maximum_validity_days()}).
            </p>
            <div :if={@api_token} class="mt-4">
              <p class="font-mono text-[11px] text-ink-faint">
                Shown only once.
              </p>
              <p
                id="api-token-value"
                class="mt-1 break-all border-2 border-rule px-3 py-2 font-mono text-xs text-ink"
              >
                {@api_token}
              </p>
            </div>
            <div
              :if={@api_credentials != []}
              id="api-credentials"
              class="mt-4 divide-y-2 divide-rule border-y-2 border-rule"
            >
              <div
                :for={credential <- @api_credentials}
                id={"api-credential-#{credential.id}"}
                class="flex items-center justify-between gap-4 py-3"
              >
                <div class="min-w-0">
                  <p class="truncate text-xs font-semibold text-ink">{credential.name}</p>
                  <p class="mt-1 font-mono text-[11px] text-ink-faint">
                    {credential.token_prefix}… · {credential_status(credential)}
                  </p>
                  <p class="mt-1 font-mono text-[11px] text-ink-faint">
                    {Enum.join(credential.scopes, " · ")}
                    <span :if={credential.repository}>
                      · {credential.repository.owner}/{credential.repository.name}
                    </span>
                  </p>
                </div>
                <.button
                  :if={ApiCredential.active?(credential)}
                  id={"revoke-api-credential-#{credential.id}"}
                  phx-click="revoke_api_credential"
                  phx-value-id={credential.id}
                  data-confirm="Revoke this credential? Clients using it will immediately lose access."
                >
                  Revoke
                </.button>
              </div>
            </div>
            <.form
              for={@credential_form}
              id="api-credential-form"
              phx-submit="generate_api_token"
              class="mt-5 space-y-4 border-t-2 border-rule pt-5"
            >
              <.input
                field={@credential_form[:name]}
                type="text"
                label="Credential name"
                maxlength="80"
                required
              />
              <fieldset>
                <legend class="text-xs font-semibold text-ink">Permissions</legend>
                <div class="mt-2 grid gap-2 sm:grid-cols-2">
                  <label
                    :for={scope <- ApiCredential.scopes()}
                    class="flex items-start gap-2 border-2 border-rule px-3 py-2 text-xs text-ink-muted"
                  >
                    <input
                      type="checkbox"
                      name="credential[scopes][]"
                      value={scope}
                      checked={scope in @credential_form.params["scopes"]}
                      class="mt-0.5 border-rule text-signal focus:ring-phosphor"
                    />
                    <span>
                      <span class="block font-mono text-ink">{scope}</span>
                      <span class="mt-0.5 block text-ink-faint">{credential_scope_label(scope)}</span>
                    </span>
                  </label>
                </div>
              </fieldset>
              <.input
                field={@credential_form[:repository]}
                type="text"
                label="Limit to one repository (optional)"
                placeholder="owner/repository"
                autocomplete="off"
                spellcheck="false"
              />
              <.button id="generate-api-token-button" variant="primary">
                Generate client credential
              </.button>
            </.form>

            <details id="api-reference" class="group mt-5 border-t-2 border-rule pt-5">
              <summary class="flex cursor-pointer list-none items-center justify-between gap-4 text-sm font-semibold text-ink marker:hidden">
                <span>API reference</span>
                <span class="font-mono text-[11px] font-normal uppercase tracking-[0.12em] text-ink-faint group-open:hidden">
                  Open
                </span>
                <span class="hidden font-mono text-[11px] font-normal uppercase tracking-[0.12em] text-ink-faint group-open:inline">
                  Close
                </span>
              </summary>

              <div class="mt-4 space-y-5 text-xs leading-5 text-ink-muted">
                <div>
                  <p class="font-semibold text-ink">Authentication</p>
                  <p class="mt-1">
                    Base URL:
                    <code id="api-reference-base-url" class="font-mono text-ink">{@api_base_url}</code>
                  </p>
                  <p>
                    Send <code class="font-mono text-ink">Authorization: Bearer &lt;token&gt;</code>
                    and <code class="font-mono text-ink">Accept: application/json</code>.
                  </p>
                  <pre class="mt-2 overflow-x-auto border-2 border-rule bg-ground p-3 font-mono text-[11px] leading-5 text-ink"><code>curl "{@api_base_url}/jobs" \
    -H "Authorization: Bearer $TARAKAN_API_TOKEN" \
    -H "Accept: application/json"</code></pre>
                </div>

                <div>
                  <p class="font-semibold text-ink">Client authorization</p>
                  <dl class="mt-2 grid gap-x-3 gap-y-1 font-mono text-[11px] sm:grid-cols-[4rem_1fr]">
                    <dt class="text-ink">POST</dt><dd>/client-auth/start</dd>
                    <dt class="text-ink">POST</dt><dd>/client-auth/exchange</dd>
                    <dt class="text-ink">DELETE</dt><dd>/client-auth/session</dd>
                  </dl>
                  <p class="mt-2">
                    Start with <code class="font-mono text-ink">&#123;&quot;client_name&quot;:&quot;Tarakan Client&quot;&#125;</code>,
                    open the returned verification URL, then poll exchange with
                    <code class="font-mono text-ink">&#123;&quot;device_code&quot;:&quot;...&quot;&#125;</code>
                    at the returned interval. Session revocation requires the issued bearer token.
                  </p>
                </div>

                <div>
                  <p class="font-semibold text-ink">Repository discovery</p>
                  <dl class="mt-2 grid gap-x-3 gap-y-1 font-mono text-[11px] sm:grid-cols-[4rem_1fr]">
                    <dt class="text-ink">GET</dt><dd>/repositories</dd>
                  </dl>
                  <p class="mt-2">
                    Optional query parameters:
                    <code class="font-mono text-ink">status=unscanned</code>
                    and <code class="font-mono text-ink">limit=100</code>.
                    Requires <code class="font-mono text-ink">repositories:read</code>.
                  </p>
                </div>

                <div>
                  <p class="font-semibold text-ink">Jobs</p>
                  <dl class="mt-2 grid gap-x-3 gap-y-1 font-mono text-[11px] sm:grid-cols-[4rem_1fr]">
                    <dt class="text-ink">GET</dt><dd>/jobs</dd>
                    <dt class="text-ink">GET</dt><dd>/:host/:owner/:name/jobs</dd>
                    <dt class="text-ink">GET</dt><dd>/jobs/:id</dd>
                    <dt class="text-ink">POST</dt><dd>/jobs/:id/claim</dd>
                    <dt class="text-ink">POST</dt><dd>/jobs/:id/claim/renew</dd>
                    <dt class="text-ink">DELETE</dt><dd>/jobs/:id/claim</dd>
                    <dt class="text-ink">POST</dt><dd>/jobs/:id/complete</dd>
                  </dl>
                  <p class="mt-2">
                    Scopes: <code class="font-mono text-ink">tasks:read</code>, <code class="font-mono text-ink">tasks:claim</code>, and <code class="font-mono text-ink">contributions:write</code>.
                  </p>
                </div>

                <div>
                  <p class="font-semibold text-ink">Reports and Checks</p>
                  <dl class="mt-2 grid gap-x-3 gap-y-1 font-mono text-[11px] sm:grid-cols-[4rem_1fr]">
                    <dt class="text-ink">GET</dt><dd>/:host/:owner/:name/reports</dd>
                    <dt class="text-ink">POST</dt><dd>/:host/:owner/:name/reports</dd>
                    <dt class="text-ink">GET</dt><dd>/:host/:owner/:name/memory</dd>
                    <dt class="text-ink">POST</dt><dd>/:host/:owner/:name/reports/:id/check</dd>
                    <dt class="text-ink">POST</dt><dd>
                      /:host/:owner/:name/findings/:public_id/check
                    </dd>
                  </dl>
                  <p class="mt-2">
                    Use <code class="font-mono text-ink">reviews:submit</code>
                    to publish, <code class="font-mono text-ink">reviews:read</code>
                    for restricted evidence,
                    and <code class="font-mono text-ink">reviews:verify</code>
                    to check findings.
                    Checks also require qualified reviewer standing.
                  </p>
                </div>

                <div class="border-l-2 border-rule pl-3">
                  <p class="font-semibold text-ink">Repository host</p>
                  <p class="mt-1">
                    Use <code class="font-mono text-ink">github.com</code>
                    or <code class="font-mono text-ink">tarakan.lol</code>
                    for <code class="font-mono text-ink">:host</code>. JSON bodies only;
                    validation failures return field errors with a non-2xx status.
                  </p>
                </div>
              </div>
            </details>
          </section>

          <section id="ssh-keys" class="mt-5 border-2 border-strong bg-panel p-6">
            <h2 class="text-sm font-semibold text-ink">SSH keys</h2>
            <p class="mt-1 font-mono text-xs leading-5 text-ink-faint">
              git clone ssh://git@&lt;host&gt;/{@current_scope.account.handle}/&lt;name&gt;.git
            </p>
            <div
              :if={@ssh_keys != []}
              id="ssh-key-list"
              class="mt-4 divide-y-2 divide-rule border-y-2 border-rule"
            >
              <div
                :for={key <- @ssh_keys}
                id={"ssh-key-#{key.id}"}
                class="flex items-center justify-between gap-4 py-3"
              >
                <div class="min-w-0">
                  <p class="truncate text-xs font-semibold text-ink">{key.name}</p>
                  <p class="mt-1 break-all font-mono text-[11px] text-ink-faint">
                    {key.fingerprint_sha256}
                  </p>
                  <p class="mt-1 font-mono text-[11px] text-ink-faint">
                    {key.key_type} · {ssh_key_last_used(key)}
                  </p>
                </div>
                <.button
                  id={"delete-ssh-key-#{key.id}"}
                  phx-click="delete_ssh_key"
                  phx-value-id={key.id}
                  data-confirm="Remove this key? Clients using it will immediately lose SSH access."
                >
                  Remove
                </.button>
              </div>
            </div>
            <.form
              for={@ssh_key_form}
              id="ssh-key-form"
              phx-submit="add_ssh_key"
              class="mt-5 space-y-4 border-t-2 border-rule pt-5"
            >
              <.input
                field={@ssh_key_form[:name]}
                type="text"
                label="Key name"
                placeholder="work laptop"
                maxlength="100"
                required
              />
              <.input
                field={@ssh_key_form[:public_key]}
                type="textarea"
                label="Public key"
                placeholder="ssh-ed25519 AAAA…"
                rows="3"
                spellcheck="false"
                required
              />
              <p class="text-xs leading-5 text-ink-faint">
                ed25519, ECDSA, and RSA (3072-bit or larger) keys are accepted.
              </p>
              <.button id="add-ssh-key-button" variant="primary">Add SSH key</.button>
            </.form>
          </section>
        </div>
      </Layouts.page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_account_email(socket.assigns.current_scope.account, token) do
        {:ok, _account} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/accounts/settings")}
  end

  def mount(_params, _session, socket) do
    account = socket.assigns.current_scope.account
    email_changeset = Accounts.change_account_email(account, %{}, validate_unique: false)
    password_changeset = Accounts.change_account_password(account, %{}, hash_password: false)

    identity_providers =
      account
      |> Accounts.list_external_identities()
      |> MapSet.new(& &1.provider)

    socket =
      socket
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:identity_providers, identity_providers)
      |> assign(:trigger_submit, false)
      |> assign(:api_token, nil)
      |> assign(:api_credentials, ApiCredentials.list(account))
      |> assign(:api_base_url, TarakanWeb.Endpoint.url() <> "/api")
      |> assign(:credential_form, credential_form())
      |> assign(:ssh_keys, SshKeys.list_for_account(account))
      |> assign(:ssh_key_form, ssh_key_form())

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"account" => account_params} = params

    email_form =
      socket.assigns.current_scope.account
      |> Accounts.change_account_email(account_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"account" => account_params} = params

    with :ok <- ensure_sudo(socket),
         account <- socket.assigns.current_scope.account do
      case Accounts.change_account_email(account, account_params) do
        %{valid?: true} = changeset ->
          Accounts.deliver_account_update_email_instructions(
            Ecto.Changeset.apply_action!(changeset, :insert),
            account.email,
            &url(~p"/accounts/settings/confirm-email/#{&1}")
          )

          info = "A link to confirm your email change has been sent to the new address."
          {:noreply, socket |> put_flash(:info, info)}

        changeset ->
          {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
      end
    else
      {:error, :sudo_required} -> reauth_settings(socket)
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"account" => account_params} = params

    password_form =
      socket.assigns.current_scope.account
      |> Accounts.change_account_password(account_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("generate_api_token", %{"credential" => params}, socket) do
    with :ok <- ensure_sudo(socket),
         account <- socket.assigns.current_scope.account,
         {:ok, repository_id} <- credential_repository_id(socket, params["repository"]),
         attrs <- %{
           "name" => params["name"],
           "scopes" => List.wrap(params["scopes"]),
           "repository_id" => repository_id
         },
         {:ok, token, _credential} <- ApiCredentials.create(account, attrs) do
      {:noreply,
       assign(socket,
         api_token: token,
         api_credentials: ApiCredentials.list(account),
         credential_form: credential_form()
       )}
    else
      {:error, :sudo_required} ->
        reauth_settings(socket)

      {:error, :repository_not_found} ->
        {:noreply,
         socket
         |> assign(:credential_form, credential_form(params))
         |> put_flash(:error, "Choose a registered repository you are allowed to view.")}

      {:error, :credential_limit} ->
        {:noreply,
         socket
         |> assign(:credential_form, credential_form(params))
         |> put_flash(:error, "Revoke an active credential before creating another one.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(:credential_form, credential_form(params))
         |> put_flash(:error, "Choose a name and at least one valid permission.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The credential could not be created.")}
    end
  end

  def handle_event("generate_api_token", _params, socket) do
    handle_event(
      "generate_api_token",
      %{"credential" => socket.assigns.credential_form.params},
      socket
    )
  end

  def handle_event("revoke_api_credential", %{"id" => credential_id}, socket) do
    with :ok <- ensure_sudo(socket),
         account <- socket.assigns.current_scope.account,
         {:ok, _credential} <- ApiCredentials.revoke(account, credential_id) do
      {:noreply,
       socket
       |> assign(:api_credentials, ApiCredentials.list(account))
       |> put_flash(:info, "Client credential revoked.")}
    else
      {:error, :sudo_required} ->
        reauth_settings(socket)

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Client credential not found.")}
    end
  end

  def handle_event("add_ssh_key", %{"ssh_key" => params}, socket) do
    with :ok <- ensure_sudo(socket),
         account <- socket.assigns.current_scope.account do
      case SshKeys.add_key(account, params) do
        {:ok, _key} ->
          {:noreply,
           socket
           |> assign(:ssh_keys, SshKeys.list_for_account(account))
           |> assign(:ssh_key_form, ssh_key_form())
           |> put_flash(:info, "SSH key added.")}

        {:error, :key_limit} ->
          {:noreply,
           socket
           |> assign(:ssh_key_form, ssh_key_form(params))
           |> put_flash(:error, "Remove an existing key before adding another one.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :ssh_key_form, to_form(changeset, as: :ssh_key))}
      end
    else
      {:error, :sudo_required} -> reauth_settings(socket)
    end
  end

  def handle_event("delete_ssh_key", %{"id" => key_id}, socket) do
    with :ok <- ensure_sudo(socket),
         account <- socket.assigns.current_scope.account,
         {:ok, _key} <- SshKeys.delete_key(account, key_id) do
      {:noreply,
       socket
       |> assign(:ssh_keys, SshKeys.list_for_account(account))
       |> put_flash(:info, "SSH key removed.")}
    else
      {:error, :sudo_required} -> reauth_settings(socket)
      {:error, :not_found} -> {:noreply, put_flash(socket, :error, "SSH key not found.")}
    end
  end

  def handle_event("update_password", params, socket) do
    %{"account" => account_params} = params

    with :ok <- ensure_sudo(socket),
         account <- socket.assigns.current_scope.account do
      case Accounts.change_account_password(account, account_params) do
        %{valid?: true} = changeset ->
          {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

        changeset ->
          {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
      end
    else
      {:error, :sudo_required} -> reauth_settings(socket)
    end
  end

  defp ensure_sudo(socket) do
    if Accounts.sudo_mode?(socket.assigns.current_scope.account),
      do: :ok,
      else: {:error, :sudo_required}
  end

  defp reauth_settings(socket) do
    {:noreply,
     socket
     |> put_flash(
       :error,
       "Confirm it's you with a magic link before changing sensitive settings."
     )
     |> redirect(to: AccountAuth.reauth_path(~p"/accounts/settings"))}
  end

  defp credential_status(%ApiCredential{revoked_at: %DateTime{}}), do: "revoked"

  defp credential_status(%ApiCredential{expires_at: expires_at}) do
    if ApiCredential.active?(%ApiCredential{expires_at: expires_at}) do
      "expires " <> Calendar.strftime(expires_at, "%Y-%m-%d")
    else
      "expired"
    end
  end

  defp credential_form(params \\ %{}) do
    defaults = %{
      "name" => "Tarakan Client",
      "repository" => "",
      "scopes" => ApiCredentials.default_scopes()
    }

    to_form(Map.merge(defaults, params), as: :credential)
  end

  defp credential_repository_id(_socket, repository)
       when repository in [nil, ""],
       do: {:ok, nil}

  defp credential_repository_id(socket, reference) when is_binary(reference) do
    with {:ok, %{owner: owner, name: name}} <- Repositories.parse_github_repository(reference),
         %{} = repository <-
           Repositories.get_visible_github_repository(
             owner,
             name,
             socket.assigns.current_scope
           ) do
      {:ok, repository.id}
    else
      _invalid -> {:error, :repository_not_found}
    end
  end

  defp credential_scope_label("tasks:read"), do: "Read visible jobs"
  defp credential_scope_label("tasks:claim"), do: "Claim and release jobs"
  defp credential_scope_label("contributions:write"), do: "Submit task evidence"
  defp credential_scope_label("findings:submit"), do: "Submit quarantined scan results"
  defp credential_scope_label("reports:write"), do: "Report abuse and view your reports"

  defp credential_scope_label("reviews:read"),
    do: "Read restricted review findings (reviewer tier)"

  defp credential_scope_label("reviews:verify"), do: "Record checks on reports (reviewer tier)"
  defp credential_scope_label("repo:read"), do: "Clone your visible hosted repositories"
  defp credential_scope_label("repo:write"), do: "Push to hosted repositories you steward"
  defp credential_scope_label(scope), do: scope

  defp ssh_key_form(params \\ %{}) do
    to_form(Map.merge(%{"name" => "", "public_key" => ""}, params), as: :ssh_key)
  end

  defp ssh_key_last_used(%{last_used_at: nil}), do: "never used"

  defp ssh_key_last_used(%{last_used_at: last_used_at}),
    do: "last used " <> Calendar.strftime(last_used_at, "%Y-%m-%d")
end
