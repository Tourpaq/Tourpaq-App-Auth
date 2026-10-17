require "test_helper"

# The index extension's id must be the same on every install, because the auth app only redirects its sign-in to the
# registered https://<extension id>.chromiumapp.org/ (SPECS.md §10, §24.3). Chrome derives the id from the manifest
# "key": the first 32 hex digits of the SHA-256 of the public key (DER), written with the letters a–p. The seeds
# register that redirect URI on index-extension.
class IndexExtensionManifestTest < ActiveSupport::TestCase
  EXTENSION_ID = "cicimfifinjjjnagflnckioghehdpogc".freeze
  DIR = Rails.root.join("clients/index-extension")

  test "the manifest key fixes the extension id that the seeds register" do
    manifest = JSON.parse(DIR.join("manifest.json").read)
    assert manifest["key"].present?, "manifest.json needs a \"key\", or the id (and redirect URI) differs per install"
    der = Base64.strict_decode64(manifest["key"])
    assert_kind_of OpenSSL::PKey::RSA, OpenSSL::PKey.read(der)
    assert_not OpenSSL::PKey.read(der).private?, "only the public half is kept"
    assert_equal EXTENSION_ID, Digest::SHA256.hexdigest(der)[0, 32].tr("0-9a-f", "a-p")
    assert_includes Rails.root.join("db/seeds.rb").read, EXTENSION_ID
    assert_includes DIR.join("README.md").read, "#{EXTENSION_ID}.chromiumapp.org"
  end

  test "it signs in with chrome.identity and reads the index host, the auth host for its tokens" do
    manifest = JSON.parse(DIR.join("manifest.json").read)
    assert_includes manifest["permissions"], "identity"
    assert_includes manifest["host_permissions"], "https://index.app.journeybooking.eu/*"
    assert_includes manifest["host_permissions"], "https://auth.app.journeybooking.eu/*"
    assert_empty Dir[DIR.join("**/*")].select { File.file?(_1) && File.extname(_1).in?(%w[.pem .key .crx]) }, "no private key in the repository"
  end
end
