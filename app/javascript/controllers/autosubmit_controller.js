import { Controller } from "@hotwired/stimulus"

// Submits its form as soon as it connects: the sign-in page goes straight on to Microsoft when an
// app sent the browser here (data-controller="autosubmit" on the form). Once only: not again for a
// Turbo preview or a second connect, and the button is disabled once the form is on its way, so a
// click during the redirect does not start a second sign-in.
export default class extends Controller {
  connect() {
    if (document.documentElement.hasAttribute("data-turbo-preview")) return
    if (this.element.dataset.autosubmitted) return
    this.element.dataset.autosubmitted = "true"
    this.element.requestSubmit()
    this.element.querySelectorAll("button[type=submit]").forEach((button) => { button.disabled = true })
  }
}
