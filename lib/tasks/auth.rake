# Break-glass console tasks (SPECS.md §15): work from the container console without a web session.
#
#   bin/rails "auth:admin[mwi@tourpaq.com]"     make an admin (creates a pre-created user if unknown)
#   bin/rails "auth:disable[someone@tourpaq.com]"
#
# The Dashboard migration (SPECS.md §23.5):
#
#   bin/rails "auth:import_dashboard[dashboard-export.json]"            dry run: the report, nothing changed
#   APPLY=1 bin/rails "auth:import_dashboard[dashboard-export.json]"    applies it (idempotent)
#   FORCE=1 APPLY=1 bin/rails "auth:import_dashboard[...]"             applies it again after an applied run
#                                                                       (later changes in the auth app are kept)
#
# The index merge (SPECS.md §24.3): Tourpaq-App-WWW's content, exported there with script/index_export.rb:
#
#   bin/rails "auth:import_index[tourpaq-index-export.json]"            dry run: the report, nothing changed
#   APPLY=1 bin/rails "auth:import_index[tourpaq-index-export.json]"    applies it (idempotent; edits made here since
#                                                                       the last applied import are kept)
#
# Local testing of an app against this auth app (SPECS.md §24.4):
#
#   bin/rails "auth:client_secret[irm-web]"   a new secret for a web client, printed once with the LOGIN_* lines
#                                             (audited client.secret_created; refused in production unless FORCE=1)
#
# In a deployed container: docker exec -it <web container> bin/rails "auth:admin[...]"
namespace :auth do
  desc "Make a user an admin of the auth app (pre-creates the user when the email is unknown)"
  task :admin, [ :email ] => :environment do |_, args|
    Current.channel = "console"
    email = args[:email].to_s.strip.downcase
    abort "Usage: bin/rails \"auth:admin[email]\"" if email.blank?
    user = User.find_by_email(email)
    unless user
      user = User.create!(email: email)
      AuditEvent.record("user.precreated", subject: user, actor: nil, data: { email: email })
      puts "Pre-created #{email}: bound at their first sign-in."
    end
    user.enable!(actor: nil) if user.disabled?
    if user.make_admin!(actor: nil)
      puts "#{user.email} is now an admin."
    else
      puts "#{user.email} is already an admin."
    end
  rescue ActiveRecord::RecordInvalid => e
    abort e.message
  end

  desc "Disable a user: ends their sessions and revokes their extension tokens"
  task :disable, [ :email ] => :environment do |_, args|
    Current.channel = "console"
    abort "Usage: bin/rails \"auth:disable[email]\"" if args[:email].blank?
    user = User.find_by_email(args[:email]) or abort "No user with email #{args[:email]}."
    abort "#{user.email} is already disabled." if user.disabled?
    user.disable!(actor: nil, reason: "console")
    puts "#{user.email} is disabled: sessions ended, extension tokens revoked, personal tokens refused."
  rescue ActiveRecord::RecordInvalid => e
    abort e.message
  end

  desc "Import the Dashboard's users, groups and memberships from its export (dry run unless APPLY=1; FORCE=1 after an applied run)"
  task :import_dashboard, [ :path ] => :environment do |_, args|
    Current.channel = "console"
    path = args[:path].to_s
    abort "Usage: bin/rails \"auth:import_dashboard[dashboard-export.json]\" (APPLY=1 to apply)" if path.blank?
    abort "No such file: #{path}" unless File.file?(path)
    report = DashboardImport.call(File.read(path), apply: ENV["APPLY"] == "1", force: ENV["FORCE"] == "1",
                                                   source: File.basename(path))
    puts report
  rescue DashboardImport::Refused => e
    abort "Refused: #{e.message}"
  end

  desc "Import Tourpaq-App-WWW's index content from its tourpaq-index-export file (dry run unless APPLY=1)"
  task :import_index, [ :path ] => :environment do |_, args|
    Current.channel = "console"
    path = args[:path].to_s
    abort "Usage: bin/rails \"auth:import_index[tourpaq-index-export.json]\" (APPLY=1 to apply)" if path.blank?
    abort "No such file: #{path}" unless File.file?(path)
    puts Index::Import.call(File.read(path), apply: ENV["APPLY"] == "1", source: File.basename(path))
  rescue Index::Import::Refused => e
    abort "Refused: #{e.message}"
  end

  desc "Create a new secret for a web client and print it once (local testing; refused in production unless FORCE=1)"
  task :client_secret, [ :client_id ] => :environment do |_, args|
    Current.channel = "console"
    client_id = args[:client_id].to_s.strip
    abort "Usage: bin/rails \"auth:client_secret[client_id]\" (e.g. irm-web)" if client_id.blank?
    if Rails.env.production? && ENV["FORCE"] != "1"
      abort "Refused in production: create the secret in the admin UI (or run again with FORCE=1)."
    end
    client = Client.find_by(client_id: client_id.downcase) or abort "No client #{client_id}."
    abort "#{client.client_id} is a #{client.kind} client: only web clients have secrets." unless client.web?
    abort "#{client.client_id} is disabled (or its app is): enable it in the admin UI first." unless client.active?
    plain = client.generate_secret!(expires_at: 1.year.from_now, created_by: nil)
    puts "A new secret for #{client.client_id} (#{client.app.name}), expires #{1.year.from_now.to_date.iso8601}."
    puts "It is shown only now; only its hash is kept. Put these in the app's environment:"
    puts
    puts "LOGIN_ISSUER=#{AuthHosts.auth_url}"
    puts "LOGIN_CLIENT_ID=#{client.client_id}"
    puts "LOGIN_CLIENT_SECRET=#{plain}"
    puts
    puts "A client holds at most #{Client::MAX_ACTIVE_SECRETS} active secrets: delete old ones in the admin UI."
  rescue Client::TooManySecrets => e
    abort "Refused: #{e.message} (in the admin UI, on the client's page)."
  end
end
