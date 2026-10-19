# A group a doc section is visible to (Index::DocSection visibility "groups").
class Index::DocSectionGroup < ApplicationRecord
  belongs_to :doc_section, class_name: "Index::DocSection"
  belongs_to :group, class_name: "::Group"
end
