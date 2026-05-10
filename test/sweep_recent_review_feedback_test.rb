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
        body: "\n**P1 Badge** correlation path can fall back to task id\n\nDetails"
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

  def test_guardrail_backlog_ranks_recurring_feedback_classes
    ledger = {
      "schema_version" => "evalops.review_feedback_ledger.v1",
      "owner" => "evalops",
      "merged_since" => "2026-04-10",
      "min_severity" => "high",
      "finding_count" => 4,
      "findings" => [
        {
          "repo" => "evalops/platform",
          "pr_number" => 1545,
          "pr_title" => "proto: regenerate SDKs",
          "feedback_url" => "https://github.com/evalops/platform/pull/1545#discussion_r1",
          "path" => "proto/codex/v1/codex.proto",
          "line" => 42,
          "severity" => "p1",
          "body_first_line" => "**P1 Badge** generated TypeScript SDK is stale"
        },
        {
          "repo" => "evalops/proto",
          "pr_number" => 88,
          "pr_title" => "buf: add meter event",
          "feedback_url" => "https://github.com/evalops/proto/pull/88#discussion_r2",
          "path" => "gen/go/meter/v1/event.pb.go",
          "line" => 7,
          "severity" => "high",
          "body_first_line" => "**High Severity** generated Go output was not committed"
        },
        {
          "repo" => "evalops/deploy",
          "pr_number" => 2137,
          "pr_title" => "ci: tighten deploy workflow",
          "feedback_url" => "https://github.com/evalops/deploy/pull/2137#discussion_r3",
          "path" => ".github/workflows/deploy.yml",
          "line" => 12,
          "severity" => "high",
          "body_first_line" => "**High Severity** workflow shell masks failed command"
        },
        {
          "repo" => "evalops/deploy",
          "pr_number" => 2142,
          "pr_title" => "test: add staging smoke",
          "feedback_url" => "https://github.com/evalops/deploy/pull/2142#discussion_r4",
          "path" => "tests/preflight/test_agent_runtime_staging.py",
          "line" => 99,
          "severity" => "medium",
          "body_first_line" => "**Medium Severity** smoke evidence omits runtime metadata"
        }
      ]
    }

    backlog = EvalOpsReviewFeedbackSweep.guardrail_backlog_json(
      ledger,
      generated_at: Time.utc(2026, 5, 10, 4, 30, 0)
    )

    assert_equal "evalops.review_feedback_guardrail_backlog.v1", backlog.fetch("schema_version")
    assert_equal "evalops.review_feedback_ledger.v1", backlog.fetch("source_schema_version")
    assert_equal "2026-05-10T04:30:00Z", backlog.fetch("generated_at")
    assert_equal 4, backlog.fetch("source_finding_count")
    assert_equal 3, backlog.fetch("class_count")

    first = backlog.fetch("classes").first
    assert_equal "generated-contract-drift", first.fetch("key")
    assert_equal 140, first.fetch("score")
    assert_equal 2, first.fetch("finding_count")
    assert_equal ["evalops/platform", "evalops/proto"], first.fetch("repos")
    assert_equal "evalops/platform", first.fetch("sample_findings").first.fetch("repo")

    markdown = EvalOpsReviewFeedbackSweep.guardrail_backlog_markdown(backlog)
    assert_includes markdown, "# Review feedback guardrail backlog"
    assert_includes markdown, "| 1 | `generated-contract-drift` Generated contract drift | 140 | 2 | evalops/platform, evalops/proto |"
    assert_includes markdown, "<!-- evalops-review-feedback-guardrail-backlog -->"

    JSON.parse(JSON.pretty_generate(backlog))
  end

  def test_guardrail_backlog_records_empty_ledgers
    backlog = EvalOpsReviewFeedbackSweep.guardrail_backlog_json(
      {
        "schema_version" => "evalops.review_feedback_ledger.v1",
        "owner" => "evalops",
        "merged_since" => "2026-04-10",
        "min_severity" => "p1",
        "finding_count" => 0,
        "findings" => []
      },
      generated_at: Time.utc(2026, 5, 10, 4, 30, 0)
    )

    assert_equal 0, backlog.fetch("source_finding_count")
    assert_equal 0, backlog.fetch("class_count")
    assert_equal [], backlog.fetch("classes")
    assert_includes EvalOpsReviewFeedbackSweep.guardrail_backlog_markdown(backlog), "No guardrail candidates found."
  end

  def test_body_first_line_skips_codex_review_boilerplate
    body = <<~BODY

      ### Codex Review

      https://github.com/evalops/platform/blob/abc/internal/agentruntime/store.go#L10-L12
      **<sub><sub>![P1 Badge](https://img.shields.io/badge/P1-orange?style=flat)</sub></sub>  Roll back tx before loading idempotent receipt**

      Details.
    BODY

    assert_equal "Roll back tx before loading idempotent receipt", EvalOpsReviewFeedbackSweep.body_first_line(body)
  end
end
