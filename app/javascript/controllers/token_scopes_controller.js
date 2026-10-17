import { Controller } from "@hotwired/stimulus"

// The Tokens page (SPECS.md §9.1, §23.3): each app has its own ordered token scopes (read / read_write by
// default, the Dashboard's public / all). When the app select changes, the scope select is refilled with that
// app's scopes, lowest first. The server checks the scope anyway.
//
//   <form data-controller="token-scopes" data-token-scopes-scopes-value='{"1":[["Read only","read"],…]}'>
//     <select data-token-scopes-target="app" data-action="token-scopes#update">…</select>
//     <select data-token-scopes-target="scope">…</select>
export default class extends Controller {
  static targets = ["app", "scope"]
  static values = { scopes: Object }

  update() {
    const options = this.scopesValue[this.appTarget.value]
    if (!options || !this.hasScopeTarget) return
    const current = this.scopeTarget.value
    this.scopeTarget.replaceChildren(...options.map(([label, value]) => {
      const option = document.createElement("option")
      option.value = value
      option.textContent = label
      return option
    }))
    if (options.some(([, value]) => value === current)) this.scopeTarget.value = current
  }
}
