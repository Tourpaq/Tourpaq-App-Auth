import { Controller } from "@hotwired/stimulus"

// The admin host's entry form (SPECS.md §24.3): add and remove link rows, and keep the order they are shown in.
//
//   <fieldset data-controller="index-links">
//     <div data-index-links-target="list">…rows (data-index-links-row, a hidden data-index-links-position)…</div>
//     <template data-index-links-target="template">…a row with NEW_LINK as its index…</template>
//     <button type="button" data-action="index-links#add">
//     (in a new row) <button type="button" data-action="index-links#remove">
export default class extends Controller {
  static targets = ["list", "template"]

  connect() {
    this.form = this.element.closest("form")
    this.onSubmit = () => {
      this.listTarget.querySelectorAll("[data-index-links-position]").forEach((input, i) => { input.value = i })
    }
    this.form?.addEventListener("submit", this.onSubmit)
  }

  disconnect() {
    this.form?.removeEventListener("submit", this.onSubmit)
  }

  add() {
    const html = this.templateTarget.innerHTML.replaceAll("NEW_LINK", Date.now().toString())
    this.listTarget.insertAdjacentHTML("beforeend", html)
    this.listTarget.lastElementChild?.querySelector("input[type=text]")?.focus()
  }

  remove(event) {
    event.target.closest("[data-index-links-row]")?.remove()
  }
}
