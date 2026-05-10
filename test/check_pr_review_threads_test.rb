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

  def test_detects_severity_markers_on_later_thread_comments
    payload = {
      "data" => {
        "repository" => {
          "pullRequest" => {
            "reviewThreads" => {
              "nodes" => [
                thread(
                  "T1",
                  resolved: false,
                  outdated: false,
                  body: "initial note",
                  comments: [
                    comment("initial note", url: "https://github.com/evalops/example/pull/1#discussion-1"),
                    comment("**High Severity** follow-up", url: "https://github.com/evalops/example/pull/1#discussion-2")
                  ]
                )
              ]
            }
          }
        }
      }
    }

    threads = EvalOpsReviewThreadGuard.unresolved_threads(payload, min_severity: "high")

    assert_equal ["T1"], threads.map { |thread| thread.fetch(:id) }
    assert_equal "high", threads.first.fetch(:severity)
    assert_equal "https://github.com/evalops/example/pull/1#discussion-2", threads.first.fetch(:url)
  end

  def test_detects_top_level_pr_comment_severity_markers
    payload = payload_with(
      comments: [
        {
          "author" => { "login" => "reviewer" },
          "body" => "**High Severity** release mirror can bypass review debt",
          "url" => "https://github.com/evalops/example/pull/1#issuecomment-1"
        }
      ]
    )

    feedback = EvalOpsReviewThreadGuard.blocking_feedback(payload, min_severity: "high")

    assert_equal ["pr_comment"], feedback.map { |item| item.fetch(:kind) }
    assert_equal "high", feedback.first.fetch(:severity)
  end

  def test_detects_top_level_review_body_severity_markers
    payload = payload_with(
      reviews: [
        {
          "author" => { "login" => "reviewer" },
          "state" => "COMMENTED",
          "body" => "**P1 Badge** paired public PR feedback is missing",
          "url" => "https://github.com/evalops/example/pull/1#pullrequestreview-1"
        }
      ]
    )

    feedback = EvalOpsReviewThreadGuard.blocking_feedback(payload, min_severity: "high")

    assert_equal ["pr_review"], feedback.map { |item| item.fetch(:kind) }
    assert_equal "p1", feedback.first.fetch(:severity)
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

  def payload_with(comments: [], reviews: [], threads: [])
    {
      "data" => {
        "repository" => {
          "pullRequest" => {
            "comments" => { "nodes" => comments },
            "reviews" => { "nodes" => reviews },
            "reviewThreads" => { "nodes" => threads }
          }
        }
      }
    }
  end

  def thread(id, resolved:, outdated:, body:, comments: nil)
    {
      "id" => id,
      "isResolved" => resolved,
      "isOutdated" => outdated,
      "path" => "app/main.go",
      "line" => 42,
      "comments" => {
        "nodes" => comments || [comment(body)]
      }
    }
  end

  def comment(body, url: "https://github.com/evalops/example/pull/1#discussion")
    {
      "body" => body,
      "url" => url
    }
  end
end
