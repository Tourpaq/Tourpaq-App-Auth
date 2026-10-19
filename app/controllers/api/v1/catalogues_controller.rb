# PUT /api/v1/catalogue (SPECS.md §23.2): the calling app pushes its whole permission catalogue, which replaces
# the stored one. Client authentication as for the rest of the API (§8: the app's web client, HTTP Basic).
#
#   PUT /api/v1/catalogue
#   Content-Type: application/json
#   { "permissions": [ { "key": "module:customers:view", "label": "Customers", "group": "Modules" }, … ] }
#
#   200 { "app": "home", "count": 42, "added": [...], "removed": [...], "changed": [...],
#         "unknown": [ { "role": "Support", "permissions": ["old:key"] } ] }
#   400 { "error": "invalid_request", "error_description": "…" }   (nothing changed)
#
# Audited app.catalogue_pushed when the catalogue changed (CataloguePush).
class Api::V1::CataloguesController < Api::BaseController
  MAX_BODY = 1.megabyte

  # Before client authentication, which reads (and so parses) the parameters.
  prepend_before_action { invalid("The body is larger than #{MAX_BODY / 1024} KB") if request.content_length.to_i > MAX_BODY }

  def update
    body = JSON.parse(request.raw_post.to_s)
    return invalid("The body must be a JSON object with a permissions list") unless body.is_a?(Hash) && body.key?("permissions")
    render json: CataloguePush.call(current_app, body["permissions"])
  rescue JSON::ParserError
    invalid("The body is not JSON")
  rescue CataloguePush::Invalid => e
    invalid(e.message)
  end

  private

  def invalid(description) = render(json: { error: "invalid_request", error_description: description }, status: :bad_request)
end
