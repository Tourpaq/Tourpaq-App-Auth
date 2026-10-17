import { Controller } from "@hotwired/stimulus"

// Filter bars: submits the form when a select or checkbox changes (data-controller="submit-on-change"
// on the form). Text fields submit on Enter as usual; the Filter button stays for keyboards and
// browsers without JavaScript.
export default class extends Controller {
  connect() {
    this.onChange = event => {
      if (event.target.matches("select, input[type=checkbox], input[type=radio]")) this.element.requestSubmit()
    }
    this.element.addEventListener("change", this.onChange)
  }

  disconnect() {
    this.element.removeEventListener("change", this.onChange)
  }
}
