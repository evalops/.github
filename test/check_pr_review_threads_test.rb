# frozen_string_literal: true

require "minitest/autorun"
require_relative "../.github/scripts/check-pr-review-threads"

class CheckPrReviewThreadsTest < Minitest::Test
  def test_detects_priority_and_high_severity_markers
    assert_equal "p1", EvalOpsReviewThreadGuard.severity("**P1 Badge** Stop the rollout")
    assert_equal "high", EvalOpsReviewThreadGuard.severity("### Bug\n\n**High Severity**")
    assert_equal "low", EvalOpsReviewThreadGuard.severity("**Low Severity**")
    assert_equal "none", EvalOpsReviewThreadGuard.severity("nit: wording")
  end

  def test_filters_unresolved_non_outdated_threads_at_threshold
    payload = {
      "data" => {
        "repository" => {
          "pullRequest" => {
            "reviewThreads" => {
              "nodes" => [
                thread("T1", resolved: false, outdated: false, body: "**P1 Badge** broken"),
                thread("T2", resolved: false, outdated: true, body: "**High Severity** stale"),
                thread("T3", resolved: true, outdated: false, body: "**High Severity** fixed"),
                thread("T4", resolved: false, outdated: false, body: "**Low Severity** polish")
              ]
            }
          }
        }
      }
    }

    threads = EvalOpsReviewThreadGuard.unresolved_threads(payload, min_severity: "high")

    assert_equal ["T1"], threads.map { |thread| thread.fetch(:id) }
  end

  def test_can_include_outdated_threads_when_requested
    payload = {
      "data" => {
        "repository" => {
          "pullRequest" => {
            "reviewThreads" => {
              "nodes" => [
                thread("T1", resolved: false, outdated: true, body: "**High Severity** stale")
              ]
            }
          }
        }
      }
    }

    threads = EvalOpsReviewThreadGuard.unresolved_threads(
      payload,
      min_severity: "high",
      include_outdated: true
    )

    assert_equal ["T1"], threads.map { |thread| thread.fetch(:id) }
  end

  private

  def thread(id, resolved:, outdated:, body:)
    {
      "id" => id,
      "isResolved" => resolved,
      "isOutdated" => outdated,
      "path" => "app/main.go",
      "line" => 42,
      "comments" => {
        "nodes" => [
          {
            "body" => body,
            "url" => "https://github.com/evalops/example/pull/1#discussion"
          }
        ]
      }
    }
  end
end
