# frozen_string_literal: true

require "minitest/autorun"
require_relative "../.github/scripts/publish-codex-structured-review"

class PublishCodexStructuredReviewTest < Minitest::Test
  def test_normalize_path_strips_workspace_prefix
    path = "/tmp/workspace/services/api/main.go"

    assert_equal(
      "services/api/main.go",
      CodexStructuredReview.normalize_path(path, workspace: "/tmp/workspace")
    )
  end

  def test_finding_payload_builds_single_line_comment
    finding = {
      "title" => "Nil pointer on empty response",
      "body" => "The new path dereferences response before checking nil.",
      "confidence_score" => 0.87,
      "priority" => 1,
      "code_location" => {
        "absolute_file_path" => "./internal/api/handler.go",
        "line_range" => {
          "start" => 42,
          "end" => 42
        }
      }
    }

    payload = CodexStructuredReview.finding_payload(finding, commit: "abc123")

    assert_equal "abc123", payload.fetch(:commit_id)
    assert_equal "internal/api/handler.go", payload.fetch(:path)
    assert_equal 42, payload.fetch(:line)
    assert_equal "RIGHT", payload.fetch(:side)
    refute payload.key?(:start_line)
    assert_includes payload.fetch(:body), "Priority: P1"
    assert_includes payload.fetch(:body), "Confidence: 0.87"
  end

  def test_finding_payload_orders_multiline_range
    finding = {
      "title" => "Range",
      "body" => "Body",
      "confidence_score" => 0.5,
      "priority" => 2,
      "code_location" => {
        "absolute_file_path" => "pkg/foo.go",
        "line_range" => {
          "start" => 12,
          "end" => 10
        }
      }
    }

    payload = CodexStructuredReview.finding_payload(finding, commit: "abc123")

    assert_equal 10, payload.fetch(:start_line)
    assert_equal 12, payload.fetch(:line)
    assert_equal "RIGHT", payload.fetch(:start_side)
  end

  def test_summary_body_contains_marker_and_verdict
    review = {
      "overall_correctness" => "patch is incorrect",
      "overall_explanation" => "One high-risk regression remains.",
      "overall_confidence_score" => 0.91,
      "findings" => [{ "title" => "Issue" }]
    }

    body = CodexStructuredReview.summary_body(review)

    assert_includes body, CodexStructuredReview::MARKER
    assert_includes body, "Verdict: patch is incorrect"
    assert_includes body, "Findings: 1"
  end
end
