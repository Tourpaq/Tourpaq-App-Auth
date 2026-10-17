# Access checks and introspections are counted per client and day instead of audited (SPECS.md §12).
#   UsageCount.increment!(client, "introspect")
class UsageCount < ApplicationRecord
  KINDS = %w[access introspect].freeze

  belongs_to :client

  validates :kind, inclusion: { in: KINDS }

  # One upsert; portable between SQLite and PostgreSQL.
  def self.increment!(client, kind, day: Date.current)
    raise ArgumentError, "unknown usage kind #{kind}" unless KINDS.include?(kind.to_s)
    upsert_all([ { client_id: client.id, day: day, kind: kind.to_s, count: 1 } ],
               unique_by: %i[client_id day kind],
               on_duplicate: Arel.sql("count = usage_counts.count + 1"))
  end
end
