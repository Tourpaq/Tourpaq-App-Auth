require "test_helper"
require "rake"

# bin/rails "auth:import_index[path]" (SPECS.md §24.3): dry run unless APPLY=1, refusals abort.
class ImportIndexTaskTest < ActiveSupport::TestCase
  FILE = Rails.root.join("test/fixtures/files/tourpaq-index-export.json").to_s

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("auth:import_index")
  end

  def run_task(*args, env: {})
    task = Rake::Task["auth:import_index"]
    task.reenable
    previous = env.keys.to_h { [ _1, ENV[_1] ] }
    env.each { ENV[_1] = _2 }
    out, = capture_io { task.invoke(*args) }
    out
  ensure
    previous&.each { ENV[_1] = _2 }
    Current.reset
  end

  test "a dry run by default, applied with APPLY=1, audited from the console" do
    out = run_task(FILE)
    assert_match "DRY RUN", out
    assert_nil Index::Entry.find_by(slug: "trace")

    out = run_task(FILE, env: { "APPLY" => "1" })
    assert_match "APPLIED", out
    assert Index::Entry.find_by(slug: "trace")
    run = AuditEvent.where(action: "index.imported").last
    assert_equal [ "console", "tourpaq-index-export.json" ], [ run.channel, run.data["source"] ]
  end

  test "a missing file, no path or another format aborts" do
    # run_task captures the output itself: a second capture_io around it would lock minitest's IO lock twice, which
    # deadlocks in a parallel run.
    assert_raises(SystemExit) { run_task }
    assert_raises(SystemExit) { run_task("/nope.json") }
    other = Rails.root.join("test/fixtures/files/dashboard_export.json").to_s
    assert_raises(SystemExit) { run_task(other) }
  end
end
