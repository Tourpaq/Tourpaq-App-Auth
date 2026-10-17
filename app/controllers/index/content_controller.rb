# Base of the index content pages on the INDEX host (SPECS.md §24.3): the front page, sections, entries, docs and
# search. Everything shown goes through Index::Section.visible_to / Index::Entry.visible_to for the signed-in viewer,
# in the query. The index host's session (IndexAuthentication, in Index::BaseController) is required as everywhere.
#
# Entry icons may be images from other sites (as on WWW), so these pages allow https images in the CSP; scripts and
# styles stay strict.
class Index::ContentController < Index::BaseController
  helper Index::ContentHelper

  content_security_policy do |policy|
    policy.img_src :self, :data, :https
  end

  private

  def index_viewer = @index_viewer ||= Index::Viewer.new(current_user)

  def visible_entries
    Index::Entry.visible_to(index_viewer).includes(:section, :access_level, :login_method, :links, :app)
  end

  def visible_sections = Index::Section.visible_to(index_viewer)
end
