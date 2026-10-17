# Secrets we only need to recognise (session tokens, client secrets, codes, personal and OAuth tokens)
# are stored as a SHA-256 digest plus a short hint. The plain value exists only in the response
# that creates it (SPECS.md §14). As in the IRM.
#
#   class PersonalToken < ApplicationRecord
#     include HashedToken                                  # columns token_digest / token_hint
#   class ClientSecret < ApplicationRecord
#     include HashedToken
#     hashed_token digest: :secret_digest, hint: :hint     # other column names
#
#   plain = record.assign_new_token(prefix: "tpa_irm_")    # sets digest + hint, returns the plain value
#   Model.find_by_token(plain)                             # nil for blank or unknown
module HashedToken
  extend ActiveSupport::Concern

  # 32 random bytes as unpadded urlsafe base64: 43 characters.
  RANDOM_BYTES = 32
  HINT_LENGTH = 6

  included do
    class_attribute :hashed_token_digest_column, instance_writer: false, default: :token_digest
    class_attribute :hashed_token_hint_column, instance_writer: false, default: :token_hint
  end

  class_methods do
    def hashed_token(digest: :token_digest, hint: :token_hint)
      self.hashed_token_digest_column = digest
      self.hashed_token_hint_column = hint
    end

    def token_digest(plain) = HashedToken.digest(plain)

    def find_by_token(plain)
      plain.present? ? find_by(hashed_token_digest_column => token_digest(plain)) : nil
    end
  end

  def self.digest(plain) = Digest::SHA256.hexdigest(plain.to_s)

  def self.generate(prefix: "") = "#{prefix}#{SecureRandom.urlsafe_base64(RANDOM_BYTES)}"

  # The prefix plus the first characters of the random part: enough to recognise a token in a list.
  def self.hint_for(plain, prefix: "") = plain.to_s.first(prefix.length + HINT_LENGTH)

  # Sets a new token and returns it (not saved).
  def assign_new_token(prefix: "")
    plain = HashedToken.generate(prefix: prefix)
    self[hashed_token_digest_column] = HashedToken.digest(plain)
    self[hashed_token_hint_column] = HashedToken.hint_for(plain, prefix: prefix) if hashed_token_hint_column && has_attribute?(hashed_token_hint_column)
    plain
  end

  # Constant-time comparison of a presented plain value with the stored digest.
  def token_matches?(plain)
    plain.present? && ActiveSupport::SecurityUtils.secure_compare(self[hashed_token_digest_column].to_s, HashedToken.digest(plain))
  end
end
