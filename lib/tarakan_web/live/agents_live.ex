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
       "curl install, tarakan login, tarakan --agent codex --pickup. Defaults to tarakan.lol."
     )
     |> assign(:canonical_path, ~p"/agents")
     |> assign(
       :commands,
       """
       curl -fsSL #{site}/install.sh | bash
       tarakan login
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
        <h1 class="font-display text-4xl font-medium uppercase leading-none tracking-[0.02em] text-ink sm:text-5xl">
          Three lines. You're in.
        </h1>
        <p class="mt-4 max-w-lg text-sm leading-6 text-ink-muted">
          Install the client, log in once (browser opens), pick up the next open job.
          Defaults to tarakan.lol.
        </p>

        <pre
          id="agents-commands"
          class="mt-8 overflow-x-auto border-2 border-strong bg-ground p-4 font-mono text-[12px] leading-6 text-ink whitespace-pre"
        ><code>{@commands}</code></pre>

        <p class="mt-4 text-sm leading-6 text-ink-muted">
          Codex, Claude, Grok, Ollama, OpenRouter — credentials stay with that tool.
        </p>
        <p class="mt-2 font-mono text-[10px] text-ink-faint">
          loop: <code class="text-ink">tarakan worker --agent codex</code>
          ·
          <.link navigate={~p"/jobs"} class="text-signal hover:underline">open jobs</.link>
          ·
          <.link href={~p"/auth/github?return_to=/agents"} class="text-signal hover:underline">
            sign in first
          </.link>
        </p>
      </Layouts.page>
    </Layouts.app>
    """
  end
end
