# OmniAuth's middleware answers /auth/* on whatever host the request names. Entra sign-in belongs
# to the auth host only (SPECS.md §24.1: the index, admin and back-channel hosts serve nothing of it),
# so on any other host those paths are 404 before OmniAuth sees them. OmniAuth matches its request and callback
# paths case-insensitively (/AUTH/entra_id/callback is its callback too), so this match ignores case as well.
class AuthHostOnly
  PATHS = %r{\A/auth(/|\z)}i

  def initialize(app) = @app = app

  def call(env)
    request = ActionDispatch::Request.new(env)
    if request.path.match?(PATHS) && request.host.to_s.downcase != URI(Rails.configuration.x.auth.app_url).host
      return [ 404, { "content-type" => "text/plain" }, [ "Not Found" ] ]
    end
    @app.call(env)
  end
end
