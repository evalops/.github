# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class WorkflowPrRefGuardTest < Minitest::Test
  def test_review_workflows_do_not_depend_on_synthetic_pull_request_merge_refs
    offenders = []
    workflow_paths.each do |path|
      File.readlines(path, chomp: true).each_with_index do |line, index|
        next unless line.match?(%r{refs/pull/.*/merge})

        offenders << "#{relative_path(path)}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty(
      offenders,
      "Synthetic PR merge refs disappear for open conflicting PRs. " \
      "Review automation should check out refs/pull/<n>/head, then fetch base/head SHAs for diffs.\n" \
      "#{offenders.join("\n")}"
    )
  end

  def test_upload_artifact_steps_set_retention_days
    offenders = []
    workflow_paths.each do |path|
      data = YAML.safe_load(File.read(path), aliases: true) || {}
      jobs = data.fetch("jobs", {}) || {}
      jobs.each do |job_name, job|
        Array(job && job["steps"]).each_with_index do |step, index|
          next unless step.is_a?(Hash) && step["uses"].to_s.include?("actions/upload-artifact")

          with = step["with"].is_a?(Hash) ? step["with"] : {}
          next if with.key?("retention-days")

          offenders << "#{relative_path(path)} #{job_name} step #{index + 1}"
        end
      end
    end

    assert_empty(
      offenders,
      "Every upload-artifact step must set retention-days so diagnostic artifacts do not silently keep the repo default.\n" \
      "#{offenders.join("\n")}"
    )
  end

  private

  def root
    File.expand_path("..", __dir__)
  end

  def workflow_paths
    Dir.glob(File.join(root, ".github", "{workflows,workflow-templates}", "*.{yml,yaml}")).sort
  end

  def relative_path(path)
    path.delete_prefix("#{root}/")
  end
end
