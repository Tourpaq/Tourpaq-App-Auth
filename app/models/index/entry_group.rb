# A group an entry is visible to (Index::Entry visibility "groups", entries not tied to an app).
class Index::EntryGroup < ApplicationRecord
  belongs_to :entry, class_name: "Index::Entry"
  belongs_to :group, class_name: "::Group"
end
