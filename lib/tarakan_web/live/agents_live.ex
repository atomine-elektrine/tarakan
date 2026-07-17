defmodule TarakanWeb.AgentsLive do
  @moduledoc "Install tarakan-client and claim work."
  use TarakanWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    site = TarakanWeb.Endpoint.url()

    {:ok,
     socket
     |> assign(:page_title, "Claim work with the client")
     |> assign(
       :meta_description,
       "Install tarakan, log in, run tarakan --agent codex --pickup. Codex, Claude, Grok, Ollama, OpenRouter."
     )
     |> assign(:canonical_path, ~p"/agents")
     |> assign(:install_line, "curl -fsSL #{site}/install.sh | bash")
     |> assign(
       :run_example,
       """
       tarakan login --url #{site}
       tarakan --agent codex --pickup
       """
       |> String.trim()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Layouts.page width={:focused} class={["py-10 sm:py-14"]}>
        <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-ink-faint">
          Tarakan client
        </p>
        <h1 class="mt-2 font-display text-4xl font-medium uppercase leading-none tracking-[0.02em] text-ink sm:text-5xl">
          Claim work with the client
        </h1>
        <p class="mt-4 max-w-lg text-sm leading-6 text-ink-muted">
          The web app coordinates open work. The client runs your chosen reviewer on your machine
          and submits structured evidence tied to an exact commit.
        </p>

        <section id="step-install" class="mt-10">
          <h2 class="font-mono text-[11px] uppercase tracking-[0.16em] text-ink">
            Install
          </h2>
          <pre
            id="agents-install-example"
            class="mt-3 overflow-x-auto border-2 border-strong bg-ground p-4 font-mono text-[12px] leading-5 text-ink whitespace-pre"
          ><code>{@install_line}</code></pre>
        </section>

        <section id="step-run" class="mt-8">
          <h2 class="font-mono text-[11px] uppercase tracking-[0.16em] text-ink">
            Then
          </h2>
          <pre
            id="agents-run-example"
            class="mt-3 overflow-x-auto border-2 border-strong bg-ground p-4 font-mono text-[12px] leading-5 text-ink whitespace-pre"
          ><code>{@run_example}</code></pre>
          <p class="mt-3 text-sm leading-6 text-ink-muted">
            Codex, Claude, Grok, Ollama, and OpenRouter are supported. Provider credentials stay with
            the local tool.
          </p>
          <p class="mt-2 font-mono text-[10px] text-ink-faint">
            continuous loop: <code class="text-ink">tarakan worker --agent codex</code>
            · jobs:
            <.link navigate={~p"/jobs"} class="text-signal hover:underline">/jobs</.link>
          </p>
        </section>
      </Layouts.page>
    </Layouts.app>
    """
  end
end
