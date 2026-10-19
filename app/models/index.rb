# The index content module (SPECS.md §24.3): Tourpaq-App-WWW's content merged into the auth app and served on the
# INDEX host. Models, controllers and views live in this namespace; its tables are prefixed index_.
#
#   Index::Site          the one row of site-wide text (Index::Site.current)
#   Index::Section       a menu group (WWW "category"): layout cards | table, visibility everyone | groups
#   Index::Entry         an app, service or host (WWW "app"), optionally tied to an auth App, with Index::Link rows
#   Index::AccessLevel   how an entry is reached on the network (a pill)
#   Index::LoginMethod   how you sign in to it (a pill)
#   Index::DocSection / Index::Doc   the documentation; a doc section has a visibility like a section
#   Index::Viewer        who is looking: their groups, staff or not, the apps they have access to (visibility, roles)
#   Index::Markdown      sanitised GFM rendering
#
# Visibility is enforced in the query on every surface (front page, section and entry pages, search, the API):
# Index::Section.visible_to(viewer), Index::Entry.visible_to(viewer), Index::DocSection / Index::Doc.visible_to(viewer). The code here never touches tokens, keys or
# sessions; the index host's session comes from IndexAuthentication, extension tokens from Index::ExtensionToken.
module Index
  # The auth App the index itself is registered as (its browser extension's tokens are tpx_index_…).
  APP_SLUG = "index".freeze
  # Its browser extension's public client (clients/index-extension).
  EXTENSION_CLIENT_ID = "index-extension".freeze

  # Only web links, never javascript: or data: URLs, since editors are not fully trusted (WWW's App::URL_FORMAT):
  # http(s) or a path on the index host.
  URL_FORMAT = %r{\A(?:https?://[^\s"'<>]+|/[^\s"'<>]*)\z}
  ICON_URL_FORMAT = %r{\A(?:https?://[^\s"'<>()]+|/[^\s"'<>()]*)\z}

  # Who may see a section, a doc section, or an entry that is not tied to an app: "everyone" is all Tourpaq staff
  # (an admin, or a member of a staff group: Index::Viewer#staff?), "groups" the members of the chosen groups.
  VISIBILITIES = %w[everyone groups].freeze
  VISIBILITY_OPTIONS = [ [ "All Tourpaq staff", "everyone" ], [ "Only these groups", "groups" ] ].freeze
  STAFF_LABEL = "All Tourpaq staff".freeze

  def self.table_name_prefix = "index_"
end
