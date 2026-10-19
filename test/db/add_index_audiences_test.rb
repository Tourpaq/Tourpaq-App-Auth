require "test_helper"
require Rails.root.join("db/migrate/20261019090001_add_index_audiences")

# Who sees the index (SPECS.md §24.3): the migration makes every group that exists then staff, so nobody who saw the
# index before loses anything; a group created later is not staff until an admin ticks it.
class AddIndexAudiencesTest < ActiveSupport::TestCase
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { AddIndexAudiences.new.migrate(direction) }
    [ Group, Index::DocSection ].each(&:reset_column_information)
  end

  test "existing groups become staff; doc sections are for all staff" do
    migrate(:down)
    ActiveRecord::Base.connection.execute("INSERT INTO groups (name, created_at, updated_at) VALUES ('Old', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
    migrate(:up)
    assert Group.find_by!(name: "Old").staff?
    assert_equal [ "everyone" ], Index::DocSection.distinct.pluck(:visibility)
    assert_not Group.create!(name: "New").staff?
  end
end
