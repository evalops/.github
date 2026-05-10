# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "time"
require_relative "../.github/scripts/sweep-recent-review-feedback"

class SweepRecentReviewFeedbackTest < Minitest::Test
  def test_ledger_json_emits_stable_machine_readable_feedback
    generated_at = Time.utc(2026, 5, 10, 3, 0, 0)
    items = [
      {
        kind: "review_thread",
        repo: "evalops/deploy",
        pr_number: 2371,
        pr_title: "test: harden A2A smoke metadata coverage",
        pr_url: "https://github.com/evalops/deploy/pull/2371",
        merged_at: "2026-05-10T02:50:06Z",
        severity: "p1",
        url: "https://github.com/evalops/deploy/pull/2371#discussion_r1",
        path: "tests/preflight/test_agent_runtime_staging.py",
        line: 1205,
        is_outdated: false,
        body: "**P1 Badge** correlation path can fall back to task id\n\nDetails"
      },
      {
        kind: "pr_review",
        repo: "evalops/maestro-internal",
        pr_number: 1885,
        pr_title: "test: harden staged rollout coverage",
        pr_url: "https://github.com/evalops/maestro-internal/pull/1885",
        merged_at: "2026-05-10T02:48:17Z",
        severity: "high",
        url: "https://github.com/evalops/maestro-internal/pull/1885#pullrequestreview-1",
        author: "reviewer",
        state: "COMMENTED",
        body: "**High Severity** hidden mode completion leaks"
      }
    ]

    ledger = EvalOpsReviewFeedbackSweep.ledger_json(
      items,
      owner: "evalops",
      since: "2026-05-10",
      min_severity: "high",
      generated_at: generated_at
    )

    assert_equal "evalops.review_feedback_ledger.v1", ledger.fetch("schema_version")
    assert_equal "2026-05-10T03:00:00Z", ledger.fetch("generated_at")
    assert_equal "evalops", ledger.fetch("owner")
    assert_equal "2026-05-10", ledger.fetch("merged_since")
    assert_equal "high", ledger.fetch("min_severity")
    assert_equal 2, ledger.fetch("finding_count")

    thread = ledger.fetch("findings").first
    assert_equal "evalops/deploy", thread.fetch("repo")
    assert_equal 2371, thread.fetch("pr_number")
    assert_equal "review_thread", thread.fetch("feedback_class")
    assert_equal "p1", thread.fetch("severity")
    assert_equal "tests/preflight/test_agent_runtime_staging.py", thread.fetch("path")
    assert_equal 1205, thread.fetch("line")
    assert_equal false, thread.fetch("is_outdated")
    assert_equal "**P1 Badge** correlation path can fall back to task id", thread.fetch("body_first_line")
    assert_match(/\A[0-9a-f]{64}\z/, thread.fetch("body_sha256"))

    review = ledger.fetch("findings").last
    assert_equal "top_level_pr_review", review.fetch("feedback_class")
    assert_equal "reviewer", review.fetch("author")
    assert_equal "COMMENTED", review.fetch("state")
    refute review.key?("path")

    JSON.parse(JSON.pretty_generate(ledger))
  end

  def test_ledger_json_records_empty_sweeps
    ledger = EvalOpsReviewFeedbackSweep.ledger_json(
      [],
      owner: "evalops",
      since: "2026-05-10",
      min_severity: "p1",
      generated_at: Time.utc(2026, 5, 10, 3, 0, 0)
    )

    assert_equal 0, ledger.fetch("finding_count")
    assert_equal [], ledger.fetch("findings")
  end
end
