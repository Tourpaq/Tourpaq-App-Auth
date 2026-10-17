# A group a section is visible to (Index::Section visibility "groups").
class Index::SectionGroup < ApplicationRecord
  belongs_to :section, class_name: "Index::Section"
  belongs_to :group, class_name: "::Group"
end
