# frozen_string_literal: true

require "minitest/autorun"

class WorkflowPrRefGuardTest < Minitest::Test
  def test_review_workflows_do_not_depend_on_synthetic_pull_request_merge_refs
    root = File.expand_path("..", __dir__)
    workflow_paths = Dir.glob(
      File.join(root, ".github", "{workflows,workflow-templates}", "*.{yml,yaml}")
    ).sort

    offenders = []
    workflow_paths.each do |path|
      File.readlines(path, chomp: true).each_with_index do |line, index|
        next unless line.match?(%r{refs/pull/.*/merge})

        offenders << "#{path.delete_prefix("#{root}/")}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty(
      offenders,
      "Synthetic PR merge refs disappear for open conflicting PRs. " \
      "Review automation should check out refs/pull/<n>/head, then fetch base/head SHAs for diffs.\n" \
      "#{offenders.join("\n")}"
    )
  end
end
