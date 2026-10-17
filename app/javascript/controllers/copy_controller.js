import { Controller } from "@hotwired/stimulus"

// Copy to clipboard: data-controller="copy" with data-copy-text-value="…" (or a
// data-copy-target="source" input/element) and a data-copy-target="button". Clicking the button
// copies; it wires itself, so no data-action is needed (an extra copy#copy action is harmless).
export default class extends Controller {
  static values = { text: String }
  static targets = [ "source", "button" ]

  buttonTargetConnected(button) {
    button.addEventListener("click", event => this.copy(event))
  }

  async copy(event) {
    event.preventDefault()
    if (event.copyHandled) return
    event.copyHandled = true
    const text = this.textValue ? this.textValue :
      this.hasSourceTarget ? (this.sourceTarget.value ?? this.sourceTarget.textContent).trim() : ""
    const button = this.hasButtonTarget ? this.buttonTarget : event.currentTarget
    try {
      await navigator.clipboard.writeText(text)
      this.flash(button, "Copied")
    } catch (_) {
      if (this.hasSourceTarget && this.sourceTarget.select) this.sourceTarget.select()
      this.flash(button, "Press ⌘C / Ctrl+C")
    }
  }

  flash(button, label) {
    const original = button.dataset.originalLabel || button.textContent
    button.dataset.originalLabel = original
    button.textContent = label
    clearTimeout(this.timer)
    this.timer = setTimeout(() => { button.textContent = original }, 2000)
  }
}
