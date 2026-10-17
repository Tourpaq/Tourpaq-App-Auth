import { Controller } from "@hotwired/stimulus"

// The index's sidebar search (SPECS.md §24.3), as on WWW: results as you type, from the viewer's /search.json
// (fetched once per page, filtered here), ↑/↓ to choose, Enter to open, Esc to close, and "/" focuses it from
// anywhere on the page. Without JavaScript the form still goes to /search?q=.
//
//   <form data-controller="index-search" data-index-search-url-value="/search.json">
//     <input data-index-search-target="input"> <div data-index-search-target="results" hidden></div>
export default class extends Controller {
  static targets = ["input", "results"]
  static values = { url: String }

  connect() {
    this.index = null
    this.selected = -1
    this.onInput = () => this.render()
    this.onKeydown = (event) => this.keydown(event)
    this.onFocus = () => this.load()
    this.onDocumentClick = (event) => { if (!this.element.contains(event.target)) this.hide() }
    this.onSlash = (event) => {
      if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) return
      if (/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName) || document.activeElement?.isContentEditable) return
      event.preventDefault()
      this.inputTarget.focus()
    }
    this.inputTarget.addEventListener("input", this.onInput)
    this.inputTarget.addEventListener("keydown", this.onKeydown)
    this.inputTarget.addEventListener("focus", this.onFocus)
    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("keydown", this.onSlash)
  }

  disconnect() {
    this.inputTarget.removeEventListener("input", this.onInput)
    this.inputTarget.removeEventListener("keydown", this.onKeydown)
    this.inputTarget.removeEventListener("focus", this.onFocus)
    document.removeEventListener("click", this.onDocumentClick)
    document.removeEventListener("keydown", this.onSlash)
  }

  load() {
    this.index ??= fetch(this.urlValue, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then((r) => (r.ok ? r.json() : []))
      .catch(() => [])
    return this.index
  }

  async render() {
    const terms = this.inputTarget.value.toLowerCase().split(/\s+/).filter(Boolean)
    if (!terms.length) { this.hide(); return }
    const entries = await this.load()
    const hits = entries
      .filter((e) => { const h = haystack(e); return terms.every((t) => h.includes(t)) })
      .sort((a, b) => score(b, terms) - score(a, terms))
      .slice(0, 8)
    this.selected = hits.length ? 0 : -1
    const nodes = hits.map((e, i) => hitNode(e, i === 0))
    if (hits.length) {
      const all = document.createElement("button")
      all.type = "submit"
      all.className = "ix-search-all"
      all.textContent = `All results for “${this.inputTarget.value}”`
      nodes.push(all)
    } else {
      const none = document.createElement("div")
      none.className = "ix-search-none"
      none.textContent = "Nothing matches."
      nodes.push(none)
    }
    this.resultsTarget.replaceChildren(...nodes)
    this.resultsTarget.hidden = false
  }

  keydown(event) {
    if (event.key === "ArrowDown") { event.preventDefault(); this.move(1) }
    else if (event.key === "ArrowUp") { event.preventDefault(); this.move(-1) }
    else if (event.key === "Escape") { this.hide(); this.inputTarget.blur() }
    else if (event.key === "Enter") {
      const hit = this.resultsTarget.querySelectorAll(".ix-search-hit")[this.selected]
      if (!this.resultsTarget.hidden && hit) { event.preventDefault(); window.location.assign(hit.href) }
    }
  }

  move(delta) {
    const hits = [...this.resultsTarget.querySelectorAll(".ix-search-hit")]
    if (!hits.length) return
    this.selected = (this.selected + delta + hits.length) % hits.length
    hits.forEach((h, i) => h.classList.toggle("selected", i === this.selected))
  }

  hide() {
    this.resultsTarget.hidden = true
  }
}

const haystack = (e) =>
  [e.name, e.description, e.group, e.address, e.url, e.owner, ...(e.links || [])].join(" ").toLowerCase()

const score = (e, terms) => {
  const name = String(e.name || "").toLowerCase()
  return terms.reduce((s, t) => s + (name.startsWith(t) ? 3 : name.includes(t) ? 2 : 1), 0)
}

// Only web links and paths on this site become links; everything is text (textContent), never HTML.
const safeHref = (href) => {
  const value = String(href || "")
  if (value.startsWith("/") && !value.startsWith("//")) return value
  try {
    const url = new URL(value)
    return url.protocol === "https:" || url.protocol === "http:" ? url.href : null
  } catch {
    return null
  }
}

const hitNode = (e, selected) => {
  const a = document.createElement("a")
  a.className = `ix-search-hit${selected ? " selected" : ""}`
  const href = safeHref(e.href)
  if (href) a.href = href
  const name = document.createElement("span")
  name.className = "ix-search-hit-name"
  name.textContent = `${e.icon ? `${e.icon} ` : ""}${e.name}`
  const meta = document.createElement("span")
  meta.className = "ix-search-hit-meta"
  meta.textContent = [e.group, e.address].filter(Boolean).join(" · ")
  a.append(name, meta)
  return a
}
