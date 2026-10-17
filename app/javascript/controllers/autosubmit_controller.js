import { Controller } from "@hotwired/stimulus"

// Submits its form as soon as it connects: the sign-in page goes straight on to Microsoft when an
// app sent the browser here (data-controller="autosubmit" on the form).
export default class extends Controller {
  connect() {
    this.element.requestSubmit()
  }
}
