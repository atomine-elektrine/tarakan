defmodule TarakanWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework.
  Here are useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: TarakanWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :auto_dismiss, :boolean, default: true, doc: "automatically clears ordinary toast messages"
  attr :dismiss_after, :integer, default: nil, doc: "auto-dismiss delay in milliseconds"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns =
      assigns
      |> assign_new(:id, fn -> "flash-#{assigns.kind}" end)
      |> assign(:dismiss_after, assigns.dismiss_after || default_dismiss_after(assigns.kind))

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook={@auto_dismiss && "AutoDismiss"}
      data-auto-dismiss-ms={@auto_dismiss && @dismiss_after}
      role="alert"
      class="fixed bottom-4 right-4 z-50 w-[min(24rem,calc(100vw-2rem))]"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 border-2 bg-panel px-4 py-3 text-sm text-ink shadow-2xl",
        @kind == :info && "border-strong",
        @kind == :error && "border-signal"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  defp default_dismiss_after(:info), do: 5_000
  defp default_dismiss_after(:error), do: 8_000

  @doc """
  Small notched badge with a continuous outline (or solid fill via `bg-ink` /
  `bg-signal`). Use instead of `border` + `clip-notch-sm`.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def notch_badge(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "wire-badge font-display text-[10px] uppercase tracking-[0.18em]",
        @class
      ]}
      {@rest}
    >
      <span class="wire-badge-label">{render_slot(@inner_block)}</span>
    </span>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    # Primary is filled + clip-notch (solid edge). Outline buttons omit clip-notch:
    # border + clip-path removes the top stroke.
    variants = %{
      "primary" =>
        "clip-notch bg-btn text-btn-fg hover:opacity-90 focus:outline-none focus:ring-2 focus:ring-phosphor",
      nil =>
        "border-2 border-strong text-ink hover:bg-panel focus:outline-none focus:ring-2 focus:ring-phosphor"
    }

    assigns =
      assign_new(assigns, :class, fn ->
        [
          "inline-flex items-center justify-center px-4 py-2 font-display text-sm uppercase tracking-[0.14em] transition",
          Map.fetch!(variants, assigns[:variant])
        ]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :hide_errors, :boolean,
    default: false,
    doc: "suppress inline error rendering; pair with <.field_errors> placed outside the input"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="flex items-center gap-2 text-sm text-ink-muted">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "size-4 border-strong bg-panel accent-phosphor focus:ring-phosphor"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors} :if={!@hide_errors} id={@id && "#{@id}-error"}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <label for={@id}>
        <span
          :if={@label}
          class="mb-1.5 block font-mono text-[11px] uppercase tracking-[0.16em] text-ink-faint"
        >{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class ||
              "w-full border-2 border-strong bg-panel px-3 py-2 text-ink placeholder:text-ink-faint focus:border-phosphor focus:outline-none focus:ring-0",
            @errors != [] && (@error_class || "border-signal")
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors} :if={!@hide_errors} id={@id && "#{@id}-error"}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <label for={@id}>
        <span
          :if={@label}
          class="mb-1.5 block font-mono text-[11px] uppercase tracking-[0.16em] text-ink-faint"
        >{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class ||
              "w-full border-2 border-strong bg-panel px-3 py-2 text-ink placeholder:text-ink-faint focus:border-phosphor focus:outline-none focus:ring-0",
            @errors != [] && (@error_class || "border-signal")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors} :if={!@hide_errors} id={@id && "#{@id}-error"}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div>
      <label for={@id}>
        <span
          :if={@label}
          class="mb-1.5 block font-mono text-[11px] uppercase tracking-[0.16em] text-ink-faint"
        >{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class ||
              "w-full border-2 border-strong bg-panel px-3 py-2 text-ink placeholder:text-ink-faint focus:border-phosphor focus:outline-none focus:ring-0",
            @errors != [] && (@error_class || "border-signal")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors} :if={!@hide_errors} id={@id && "#{@id}-error"}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders a field's errors on their own, for inputs embedded in composed
  controls (set `hide_errors` on the input and place this outside the frame).

  ## Examples

      <.input field={@form[:url]} hide_errors ... />
      <.field_errors field={@form[:url]} />
  """
  attr :field, Phoenix.HTML.FormField, required: true

  def field_errors(assigns) do
    errors =
      if Phoenix.Component.used_input?(assigns.field), do: assigns.field.errors, else: []

    assigns = assign(assigns, :messages, Enum.map(errors, &translate_error/1))

    ~H"""
    <.error :for={msg <- @messages} id={"#{@field.id}-error"}>{msg}</.error>
    """
  end

  # Helper used by inputs to generate form errors
  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp error(assigns) do
    ~H"""
    <p id={@id} class="mt-1.5 flex items-center gap-2 text-sm text-signal">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders the standard breadcrumb trail used at the top of interior pages.

  Crumbs with `navigate` render as links; crumbs without render as static
  text. The final crumb is the current page and reads brighter than the
  trail.

  ## Examples

      <.breadcrumbs id="finding-breadcrumb">
        <:crumb navigate={~p"/"}>registry</:crumb>
        <:crumb>finding</:crumb>
      </.breadcrumbs>
  """
  attr :id, :string, default: nil

  slot :crumb, required: true do
    attr :navigate, :string
  end

  def breadcrumbs(assigns) do
    assigns = assign(assigns, :last_index, length(assigns.crumb) - 1)

    ~H"""
    <nav
      id={@id}
      class="mb-3 flex min-w-0 flex-wrap items-center gap-2 font-mono text-xs text-ink-faint"
      aria-label="Breadcrumb"
    >
      <%= for {crumb, index} <- Enum.with_index(@crumb) do %>
        <span :if={index > 0} aria-hidden="true">/</span>
        <.link
          :if={crumb[:navigate]}
          navigate={crumb.navigate}
          class={[
            "min-w-0 truncate transition hover:text-ink",
            index == @last_index && "text-ink-muted"
          ]}
        >
          {render_slot(crumb)}
        </.link>
        <span
          :if={!crumb[:navigate]}
          class={["min-w-0 truncate", index == @last_index && "text-ink-muted"]}
        >
          {render_slot(crumb)}
        </span>
      <% end %>
    </nav>
    """
  end

  @doc """
  Renders a handle as a link to its public profile. The `@` is part of the
  link text so the whole mention is clickable.

  ## Examples

      <.handle_link handle={@scan.submitted_by.handle} />
      <.handle_link handle={comment.account.handle} class="font-semibold" />
  """
  attr :handle, :string, required: true
  attr :class, :any, default: nil

  def handle_link(assigns) do
    ~H"""
    <.link navigate={"/" <> @handle} class={["transition hover:text-signal", @class]}>@{@handle}</.link>
    """
  end

  @doc """
  Renders an up/down vote control for a votable subject (a canonical finding or a
  comment). The score is the plain net of votes; the caller's own vote is
  highlighted. Emits `phx-click="vote"` with the subject type, id, and value.

  ## Examples

      <.vote_control subject_type="canonical_finding" subject_id={@canonical.id} summary={@finding_votes} can_vote={@can_vote} />
  """
  attr :subject_type, :string, required: true
  attr :subject_id, :integer, required: true
  attr :summary, :map, default: %{score: 0, my_vote: 0}
  attr :can_vote, :boolean, default: false
  attr :class, :any, default: nil

  def vote_control(assigns) do
    ~H"""
    <div
      id={"vote-#{@subject_type}-#{@subject_id}"}
      class={["inline-flex items-center gap-1 font-mono text-[11px]", @class]}
    >
      <button
        type="button"
        phx-click="vote"
        phx-value-type={@subject_type}
        phx-value-id={@subject_id}
        phx-value-vote="1"
        disabled={!@can_vote}
        aria-label="Upvote"
        class={[
          "flex size-5 items-center justify-center transition disabled:cursor-not-allowed",
          @summary.my_vote == 1 && "text-quote",
          @summary.my_vote != 1 && "text-ink-faint enabled:hover:text-quote"
        ]}
      >
        <.icon name="hero-chevron-up-mini" class="size-4" />
      </button>
      <span class={[
        "min-w-4 text-center tabular-nums",
        @summary.score > 0 && "text-quote",
        @summary.score < 0 && "text-signal",
        @summary.score == 0 && "text-ink-muted"
      ]}>
        {@summary.score}
      </span>
      <button
        type="button"
        phx-click="vote"
        phx-value-type={@subject_type}
        phx-value-id={@subject_id}
        phx-value-vote="-1"
        disabled={!@can_vote}
        aria-label="Downvote"
        class={[
          "flex size-5 items-center justify-center transition disabled:cursor-not-allowed",
          @summary.my_vote == -1 && "text-signal",
          @summary.my_vote != -1 && "text-ink-faint enabled:hover:text-signal"
        ]}
      >
        <.icon name="hero-chevron-down-mini" class="size-4" />
      </button>
    </div>
    """
  end

  @doc """
  Renders one discussion comment and its replies, recursively.

  Nesting indents up to a fixed depth, then stops so deep chains don't run
  off the page. Removed comments render as a placeholder that keeps the
  thread intact.
  """
  attr :comment, :map, required: true
  attr :reply_to, :string, default: nil
  attr :can_reply, :boolean, default: false
  attr :can_moderate, :boolean, default: false
  attr :can_vote, :boolean, default: false
  attr :votes, :map, default: %{}

  def comment_thread(assigns) do
    ~H"""
    <div id={"comment-#{@comment.id}"} class="border-l-2 border-rule pl-3">
      <div class="flex flex-wrap items-center gap-x-2 font-mono text-[11px] text-ink-faint">
        <.vote_control
          :if={is_nil(@comment.removed_at)}
          subject_type="comment"
          subject_id={@comment.id}
          summary={Map.get(@votes, @comment.id, %{score: 0, my_vote: 0})}
          can_vote={@can_vote}
          class="mr-1"
        />
        <.handle_link handle={@comment.account.handle} class="font-semibold text-ink-muted" />
        <span class="tabular-nums">{comment_time(@comment.inserted_at)}</span>
        <span
          :if={@comment.removed_at}
          class="border border-signal px-1 text-[9px] uppercase tracking-[0.14em] text-signal"
        >
          removed
        </span>
      </div>

      <p
        :if={is_nil(@comment.removed_at)}
        class="mt-1 whitespace-pre-line text-sm leading-6 text-ink"
        phx-no-format
      >{@comment.body}</p>
      <p :if={@comment.removed_at} class="mt-1 text-sm italic leading-6 text-ink-faint">
        Removed by moderation: {@comment.removed_reason}<span
          :if={@comment.body}
          class="ml-2 not-italic"
        >- original: “{@comment.body}”</span>
      </p>

      <div class="mt-1 flex items-center gap-3 font-mono text-[10px] uppercase tracking-[0.14em]">
        <button
          :if={@can_reply and is_nil(@comment.removed_at)}
          type="button"
          phx-click="reply_to"
          phx-value-parent={@comment.id}
          class="text-ink-faint transition hover:text-ink"
        >
          Reply
        </button>
        <button
          :if={@can_moderate and is_nil(@comment.removed_at)}
          type="button"
          phx-click="remove_comment"
          phx-value-id={@comment.id}
          phx-value-reason="moderator_removed"
          data-confirm="Remove this comment from the public discussion?"
          class="text-ink-faint transition hover:text-signal"
        >
          Remove
        </button>
      </div>

      <form
        :if={@can_reply and @reply_to == to_string(@comment.id)}
        id={"reply-form-#{@comment.id}"}
        phx-submit="post_comment"
        class="mt-2 flex flex-col gap-2"
      >
        <input type="hidden" name="parent_id" value={@comment.id} />
        <textarea
          name="body"
          rows="2"
          phx-mounted={JS.focus()}
          placeholder="Add to this thread…"
          class="w-full border-2 border-strong bg-transparent px-3 py-2 font-mono text-xs text-ink placeholder:text-ink-faint focus:outline-none focus:ring-2 focus:ring-phosphor"
        ></textarea>
        <div class="flex gap-2">
          <button class="clip-notch bg-btn px-3 py-1 font-display text-[11px] uppercase tracking-[0.16em] text-btn-fg transition hover:opacity-90">
            Reply
          </button>
          <button
            type="button"
            phx-click="cancel_reply"
            class="px-3 py-1 font-display text-[11px] uppercase tracking-[0.16em] text-ink-faint transition hover:text-ink"
          >
            Cancel
          </button>
        </div>
      </form>

      <div :if={@comment.replies != []} class="mt-3 space-y-3">
        <.comment_thread
          :for={reply <- @comment.replies}
          comment={reply}
          reply_to={@reply_to}
          can_reply={@can_reply}
          can_moderate={@can_moderate}
          can_vote={@can_vote}
          votes={@votes}
        />
      </div>
    </div>
    """
  end

  defp comment_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="font-display text-2xl font-medium uppercase leading-9 tracking-[0.08em] text-ink">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-ink-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles - outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(TarakanWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(TarakanWeb.Gettext, "errors", msg, opts)
    end
  end
end
