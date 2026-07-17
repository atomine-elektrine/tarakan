// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"

// Theme: no data-theme attribute means "follow the OS"; a manual choice is
// stamped on <html> and persisted.
const syncThemeToggle = theme => {
  document.querySelectorAll("[data-theme-option]").forEach(button => {
    button.setAttribute("aria-pressed", button.dataset.themeOption === theme ? "true" : "false")
  })
}

const setTheme = theme => {
  if (theme === "system") {
    localStorage.removeItem("tarakan:theme")
    document.documentElement.removeAttribute("data-theme")
  } else {
    localStorage.setItem("tarakan:theme", theme)
    document.documentElement.setAttribute("data-theme", theme)
  }

  syncThemeToggle(theme)
}
setTheme(localStorage.getItem("tarakan:theme") || "system")
window.addEventListener("tarakan:set-theme", ({detail}) => setTheme(detail.theme))
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/tarakan"
import topbar from "../vendor/topbar"

const AutoDismiss = {
  mounted() {
    this.pause = () => this.clearTimer()
    this.resume = () => this.schedule()
    this.el.addEventListener("mouseenter", this.pause)
    this.el.addEventListener("mouseleave", this.resume)
    this.el.addEventListener("focusin", this.pause)
    this.el.addEventListener("focusout", this.resume)
    this.schedule()
  },

  updated() {
    this.schedule()
  },

  destroyed() {
    this.clearTimer()
    this.el.removeEventListener("mouseenter", this.pause)
    this.el.removeEventListener("mouseleave", this.resume)
    this.el.removeEventListener("focusin", this.pause)
    this.el.removeEventListener("focusout", this.resume)
  },

  clearTimer() {
    if (this.timer) window.clearTimeout(this.timer)
    this.timer = null
  },

  schedule() {
    this.clearTimer()
    const delay = Number(this.el.dataset.autoDismissMs || 5000)
    this.timer = window.setTimeout(() => this.el.click(), delay)
  },
}

const PinToBottom = {
  mounted() {
    this.scrollToBottom()
  },

  beforeUpdate() {
    const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
    this.pinned = distance < 60
  },

  updated() {
    if (this.pinned) this.scrollToBottom()
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
}

const SearchShortcut = {
  mounted() {
    this.onKeydown = event => {
      if (event.key !== "/" || event.defaultPrevented) return
      const target = event.target
      if (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName)) return
      event.preventDefault()
      this.el.focus()
    }
    window.addEventListener("keydown", this.onKeydown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.onKeydown)
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, AutoDismiss, PinToBottom, SearchShortcut},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#e60012"}, shadowColor: "rgba(0, 0, 0, .35)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => {
  topbar.hide()
  syncThemeToggle(localStorage.getItem("tarakan:theme") || "system")
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
