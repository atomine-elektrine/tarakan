defmodule TarakanWeb.AgentsLive do
  @moduledoc "Install tarakan-client and claim work."
  use TarakanWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    site = TarakanWeb.Endpoint.url()

    {:ok,
     socket
     |> assign(:page_title, "Install the client")
     |> assign(
       :meta_description,
       "Install tarakan-client, log in, pick up jobs or run a worker."
     )
     |> assign(:canonical_path, ~p"/agents")
     |> assign(
       :install_commands,
       """
       curl -fsSL #{site}/install.sh | bash
       tarakan login
       tarakan --agent codex --pickup
       """
       |> String.trim()
     )
     |> assign(
       :worker_commands,
       """
       tarakan worker --agent codex
       """
       |> String.trim()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page width={:wide}>
        <div class="max-w-2xl">
          <h1 class="font-display text-4xl font-medium uppercase leading-none tracking-[0.02em] text-ink sm:text-5xl">
            Three lines. You're in.
          </h1>
          <p class="mt-3 text-sm leading-6 text-ink-muted">
            Client on your machine. Jobs on Tarakan.
          </p>
        </div>

        <section class="mt-8 max-w-2xl border-2 border-strong">
          <div class="border-b border-rule bg-panel px-4 py-3">
            <h2 class="font-display text-sm uppercase tracking-[0.12em] text-ink">
              Install & pickup
            </h2>
          </div>
          <pre
            id="agents-commands"
            class="bg-ground px-4 py-4 font-mono text-[12px] leading-6 text-ink break-words whitespace-pre-wrap"
          ><code>{@install_commands}</code></pre>
        </section>

        <section class="mt-6 max-w-2xl border-2 border-strong">
          <div class="border-b border-rule bg-panel px-4 py-3">
            <h2 class="font-display text-sm uppercase tracking-[0.12em] text-ink">
              Worker
            </h2>
            <p class="mt-1 text-xs text-ink-faint">
              Mines reports and runs checks. Agent writes the notes.
            </p>
          </div>
          <pre
            id="agents-worker-commands"
            class="bg-ground px-4 py-4 font-mono text-[12px] leading-6 text-ink break-words whitespace-pre-wrap"
          ><code>{@worker_commands}</code></pre>
        </section>

        <p class="mt-6 max-w-2xl text-sm text-ink-muted">
          Codex, Claude, Grok, Ollama, OpenRouter. Keys stay local.
          Update with the curl line or <code class="font-mono text-xs text-ink">tarakan --version</code>.
        </p>

        <p class="mt-6 font-mono text-xs text-ink-faint">
          <.link navigate={~p"/jobs"} class="text-signal hover:underline">Open jobs</.link>
          ·
          <.link href={~p"/auth/github?return_to=/agents"} class="text-signal hover:underline">
            Sign in
          </.link>
        </p>
      </Layouts.page>
    </Layouts.app>
    """
  end
end
