import { Controller } from "@hotwired/stimulus"

// Click an address to copy it (WWW's data-copy): data-controller="index-copy" data-index-copy-text-value="…"
// data-action="click->index-copy#copy". The element shows "copied" for a moment.
export default class extends Controller {
  static values = { text: String }

  copy(event) {
    event.preventDefault()
    if (!navigator.clipboard) return
    navigator.clipboard.writeText(this.textValue).then(() => {
      this.element.classList.add("ix-copied")
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.element.classList.remove("ix-copied"), 1200)
    })
  }
}
