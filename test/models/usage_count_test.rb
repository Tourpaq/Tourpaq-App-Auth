require "test_helper"

class UsageCountTest < ActiveSupport::TestCase
  test "increment! counts per client, day and kind" do
    3.times { UsageCount.increment!(clients(:irm_web), "introspect") }
    UsageCount.increment!(clients(:irm_web), "access")
    UsageCount.increment!(clients(:kpi_web), "introspect")
    UsageCount.increment!(clients(:irm_web), "introspect", day: Date.yesterday)
    assert_equal 3, UsageCount.find_by(client: clients(:irm_web), day: Date.current, kind: "introspect").count
    assert_equal 1, UsageCount.find_by(client: clients(:irm_web), day: Date.current, kind: "access").count
    assert_equal 4, UsageCount.count
    assert_raises(ArgumentError) { UsageCount.increment!(clients(:irm_web), "other") }
  end
end
