# One extra destination on an entry: a dashboard, a saved log search, a runbook.
class Index::Link < ApplicationRecord
  belongs_to :entry, class_name: "Index::Entry", inverse_of: :links

  normalizes :label, :url, :note, with: ->(value) { value.strip.presence }

  validates :label, :url, presence: true
  validates :url, format: { with: Index::URL_FORMAT, message: "must start with https://, http:// or /" }, allow_nil: true
end
