class Admin::IndexContent::AccessLevelsController < Admin::IndexContent::VocabulariesController
  private

  def model = Index::AccessLevel
  def noun = "Access level"
end
