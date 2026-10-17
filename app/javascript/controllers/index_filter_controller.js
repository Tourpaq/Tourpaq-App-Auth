import { Controller } from "@hotwired/stimulus"

// Narrows a long list in place (WWW's filter): every term must appear in an item's text.
//
//   <div data-controller="index-filter">
//     <input data-index-filter-target="input" data-action="input->index-filter#filter">
//     <span data-index-filter-target="empty" hidden>Nothing matches.</span>
//     <tr data-index-filter-target="item">…</tr>
export default class extends Controller {
  static targets = ["input", "item", "empty"]

  filter() {
    const terms = this.inputTarget.value.toLowerCase().split(/\s+/).filter(Boolean)
    let shown = 0
    this.itemTargets.forEach((item) => {
      const text = item.textContent.toLowerCase()
      const match = terms.every((t) => text.includes(t))
      item.hidden = !match
      if (match) shown++
    })
    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0
  }
}
