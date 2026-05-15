# frozen_string_literal: true

require "minitest/autorun"
require_relative "../.github/scripts/sync-labels"

class SyncLabelsTest < Minitest::Test
  def test_labels_yml_is_valid
    config = EvalOpsLabelSync.load_config("labels.yml")
    assert_equal [], EvalOpsLabelSync.validation_errors(config)
    assert_equal "evalops.labels.v1", config.fetch("schema_version")
    assert config.fetch("labels").any? { |label| label.fetch("name") == "architecture-review" }
  end

  def test_plan_repo_is_additive_and_updates_matching_labels
    desired = [
      {
        "name" => "architecture-review",
        "description" => "Cross-service architecture review requested",
        "color" => "5319e7"
      },
      {
        "name" => "security",
        "description" => "Security vulnerabilities and hardening",
        "color" => "d73a4a"
      }
    ]
    existing = [
      {
        "name" => "architecture-review",
        "description" => "Old description",
        "color" => "000000"
      },
      {
        "name" => "repo-local",
        "description" => "Do not delete me",
        "color" => "cccccc"
      }
    ]

    plan = EvalOpsLabelSync.plan_repo(
      repo: "evalops/example",
      desired_labels: desired,
      existing_labels: existing
    )

    assert_equal "planned", plan.fetch("status")
    assert_equal ["security"], plan.fetch("additions").map { |label| label.fetch("name") }
    assert_equal ["architecture-review"], plan.fetch("updates").map { |label| label.fetch("name") }
    refute_includes plan.to_s, "repo-local"
  end

  def test_opted_out_repo_is_skipped
    plan = EvalOpsLabelSync.plan_repo(
      repo: "evalops/example",
      desired_labels: [{ "name" => "security", "description" => "Security", "color" => "d73a4a" }],
      existing_labels: [],
      opted_out: true
    )

    assert_equal "skipped", plan.fetch("status")
    assert_equal ["opted out"], plan.fetch("skips")
  end

  def test_label_names_are_escaped_as_path_components
    assert_equal "autorelease%3A%20pending", EvalOpsLabelSync.path_component_escape("autorelease: pending")
    assert_equal "area%2Fplatform", EvalOpsLabelSync.path_component_escape("area/platform")
  end

  def test_markdown_report_summarizes_repo_diffs
    report = {
      "generated_at" => "2026-05-15T12:00:00Z",
      "dry_run" => true,
      "label_count" => 2,
      "target_count" => 1,
      "totals" => {
        "additions" => 1,
        "updates" => 1,
        "errors" => 0
      },
      "repos" => [
        {
          "repo" => "evalops/example",
          "status" => "planned",
          "additions" => [{}],
          "updates" => [{}],
          "skips" => [],
          "errors" => []
        }
      ]
    }

    markdown = EvalOpsLabelSync.markdown_report(report)

    assert_includes markdown, "EvalOps Label Sync Report"
    assert_includes markdown, "`evalops/example`"
    assert_includes markdown, "| `evalops/example` | planned | 1 | 1 |  |"
  end
end
