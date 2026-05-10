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

  def test_skips_informational_bot_pr_summaries
    payload = payload_with(
      comments: [
        {
          "author" => { "login" => "cursor" },
          "body" => "## PR Summary\n\n| Severity | Count |\n| --- | --- |\n| P0 | 0 |",
          "url" => "https://github.com/evalops/example/pull/1#issuecomment-1"
        },
        {
          "author" => { "login" => "reviewer" },
          "body" => "**High Severity** release mirror can bypass review debt",
          "url" => "https://github.com/evalops/example/pull/1#issuecomment-2"
        }
      ],
      reviews: [
        {
          "author" => { "login" => "cursor" },
          "state" => "COMMENTED",
          "body" => "\n## Walkthrough\n\nMentions P1 as a summary bucket.",
          "url" => "https://github.com/evalops/example/pull/1#pullrequestreview-1"
        }
      ]
    )

    feedback = EvalOpsReviewThreadGuard.blocking_feedback(payload, min_severity: "high")

    assert_equal ["pr_comment"], feedback.map { |item| item.fetch(:kind) }
    assert_equal "https://github.com/evalops/example/pull/1#issuecomment-2", feedback.first.fetch(:url)
  end

  def test_first_nonblank_line_normalizes_leading_blank_review_bodies
    assert_equal "**P1 Badge** real feedback", EvalOpsReviewThreadGuard.first_nonblank_line("\n\n**P1 Badge** real feedback\n\nDetails")
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

  def test_merge_review_thread_nodes_is_nil_safe_for_partial_graphql_payloads
    partial_payloads = [
      nil,
      {},
      { "data" => nil },
      { "data" => {} },
      { "data" => { "repository" => nil } },
      { "data" => { "repository" => {} } },
      { "data" => { "repository" => { "pullRequest" => nil } } },
      { "data" => { "repository" => { "pullRequest" => {} } } },
      { "data" => { "repository" => { "pullRequest" => { "reviewThreads" => nil } } } }
    ]

    partial_payloads.each do |payload|
      merged = EvalOpsReviewThreadGuard.merge_review_thread_nodes(payload, [thread("T1", resolved: false, outdated: false, body: "**High Severity** broken")])

      assert_equal ["T1"], merged.dig("data", "repository", "pullRequest", "reviewThreads", "nodes").map { |node| node.fetch("id") }
    end
  end

  def test_merge_review_thread_nodes_survives_random_sparse_payload_shapes
    random = Random.new(12_345)
    250.times do
      payload = random_payload(random, depth: 0)
      nodes = random.rand(3).times.map do |index|
        thread("T#{index}", resolved: false, outdated: false, body: "**High Severity** broken")
      end

      merged = EvalOpsReviewThreadGuard.merge_review_thread_nodes(payload, nodes)

      assert_equal nodes, merged.dig("data", "repository", "pullRequest", "reviewThreads", "nodes")
      assert_kind_of Hash, merged.dig("data", "repository", "pullRequest", "reviewThreads")
    end
  end

  def test_merge_pull_request_connections_sets_all_feedback_channels
    merged = EvalOpsReviewThreadGuard.merge_pull_request_connections(
      {},
      comments: [{ "body" => "**High Severity** top-level" }],
      reviews: [{ "body" => "**P1 Badge** review" }],
      review_threads: [thread("T1", resolved: false, outdated: false, body: "**High Severity** thread")]
    )

    pull_request = merged.dig("data", "repository", "pullRequest")
    assert_equal ["**High Severity** top-level"], pull_request.dig("comments", "nodes").map { |node| node.fetch("body") }
    assert_equal ["**P1 Badge** review"], pull_request.dig("reviews", "nodes").map { |node| node.fetch("body") }
    assert_equal ["T1"], pull_request.dig("reviewThreads", "nodes").map { |node| node.fetch("id") }
  end

  def test_fetch_connection_tail_uses_connection_specific_cursor
    calls = []
    original = EvalOpsReviewThreadGuard.method(:fetch_graphql)
    tail_payload = connection_payload("comments", [{ "body" => "**High Severity** later page" }], has_next: false)
    EvalOpsReviewThreadGuard.define_singleton_method(:fetch_graphql) do |**kwargs|
      calls << kwargs
      tail_payload
    end

    nodes = EvalOpsReviewThreadGuard.fetch_connection_tail(
      owner: "evalops",
      name: "example",
      pr: 1,
      query: "query",
      connection_name: "comments",
      first_connection: {
        "nodes" => [{ "body" => "first page" }],
        "pageInfo" => { "hasNextPage" => true, "endCursor" => "cursor-1" }
      }
    )

    assert_equal [{ "body" => "**High Severity** later page" }], nodes
    assert_equal ["cursor-1"], calls.map { |call| call.fetch(:cursor) }
  ensure
    EvalOpsReviewThreadGuard.define_singleton_method(:fetch_graphql) do |**kwargs|
      original.call(**kwargs)
    end
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

  def connection_payload(name, nodes, has_next:)
    {
      "data" => {
        "repository" => {
          "pullRequest" => {
            name => {
              "nodes" => nodes,
              "pageInfo" => {
                "hasNextPage" => has_next,
                "endCursor" => has_next ? "next-cursor" : nil
              }
            }
          }
        }
      }
    }
  end

  def random_payload(random, depth:)
    return random_leaf(random) if depth > 4

    case random.rand(5)
    when 0
      nil
    when 1
      random_leaf(random)
    else
      keys = %w[data repository pullRequest reviewThreads nodes pageInfo comments reviews body]
      random.rand(0..4).times.each_with_object({}) do |_index, hash|
        hash[keys.sample(random: random)] = random_payload(random, depth: depth + 1)
      end
    end
  end

  def random_leaf(random)
    [nil, true, false, random.rand(100), "value", []].sample(random: random)
  end
end
