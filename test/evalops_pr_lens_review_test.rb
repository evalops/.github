# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../.github/scripts/evalops-pr-lens-review"

class EvalOpsPrLensReviewTest < Minitest::Test
  def test_parse_pr_filter_requires_repo_when_multiple_repos
    error = assert_raises(ArgumentError) do
      EvalOpsPrLensReview.parse_pr_filter("2023", repos: %w[evalops/platform evalops/deploy])
    end

    assert_includes error.message, "require exactly one target repo"
  end

  def test_parse_pr_filter_accepts_repo_number_pairs
    filter = EvalOpsPrLensReview.parse_pr_filter(
      "platform#2023,evalops/deploy#7",
      repos: %w[evalops/platform evalops/deploy]
    )

    assert_equal [2023], filter.fetch("evalops/platform")
    assert_equal [7], filter.fetch("evalops/deploy")
  end

  def test_matrix_for_uses_stable_lens_contexts
    prs = [
      {
        "repo" => "evalops/platform",
        "repo_slug" => "evalops-platform",
        "number" => 2023,
        "head_sha" => "abc123"
      }
    ]

    matrix = EvalOpsPrLensReview.matrix_for(prs, lenses: ["migration-safety"])

    assert_equal 1, matrix.length
    assert_equal "evalops-pr-lens/migration-safety", matrix.fetch(0).fetch("check_context")
    assert_equal "abc123", matrix.fetch(0).fetch("head_sha")
  end

  def test_normalize_lens_review_drops_invalid_findings
    raw = {
      "summary" => "Found one issue",
      "confidence_score" => 0.9,
      "findings" => [
        {
          "title" => "Unsafe migration",
          "body" => "The migration drops a column during a rolling deploy.",
          "confidence_score" => 0.92,
          "priority" => 1,
          "code_location" => {
            "path" => "./db/migrations/001.sql",
            "line" => 12
          }
        },
        {
          "title" => "Missing body"
        }
      ]
    }

    review = EvalOpsPrLensReview.normalize_lens_review(
      raw,
      repo: "evalops/platform",
      pr: 2023,
      lens: "migration-safety",
      head_sha: "abc123"
    )

    assert_equal "evalops-pr-lens/migration-safety", review.fetch("check_id")
    assert_equal 1, review.fetch("findings").length
    assert_equal "db/migrations/001.sql", review.fetch("findings").fetch(0).dig("code_location", "path")
  end

  def test_high_confidence_findings_filters_and_ranks_by_confidence
    reviews = [
      {
        "repo" => "evalops/platform",
        "pr" => 2023,
        "lens" => "migration-safety",
        "head_sha" => "abc123",
        "check_id" => "evalops-pr-lens/migration-safety",
        "findings" => [
          finding("Lower", 0.83, 1, "a.go", 2),
          finding("Higher", 0.95, 2, "b.go", 4),
          finding("Low confidence", 0.7, 0, "c.go", 8)
        ]
      }
    ]

    high = EvalOpsPrLensReview.high_confidence_findings(reviews, min_confidence: 0.82)
    ranked = EvalOpsPrLensReview.dedupe_and_rank(high)

    assert_equal %w[Higher Lower], ranked.map { |finding| finding.fetch("title") }
  end

  def test_comment_body_contains_only_ranked_findings
    findings = [
      finding("Unsafe IAM expansion", 0.94, 1, "infra/main.tf", 22).merge(
        "repo" => "evalops/deploy",
        "pr" => 10,
        "lens" => "iam-blast-radius",
        "head_sha" => "abc123",
        "check_id" => "evalops-pr-lens/iam-blast-radius"
      )
    ]

    body = EvalOpsPrLensReview.comment_body(
      repo: "evalops/deploy",
      pr: 10,
      findings: findings,
      min_confidence: 0.82,
      target_url: "https://github.com/evalops/.github/actions/runs/1"
    )

    assert_includes body, EvalOpsPrLensReview::MARKER
    assert_includes body, "High-confidence findings only"
    assert_includes body, "`infra/main.tf:22`"
    assert_includes body, "`evalops-pr-lens/iam-blast-radius`"
  end

  def test_anthropic_request_omits_temperature_for_opus_4_7
    request_body = nil
    fake_response = Struct.new(:body) do
      def is_a?(klass)
        klass == Net::HTTPSuccess || super
      end
    end.new(JSON.generate({ "content" => [{ "text" => "{\"findings\":[]}" }] }))
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      request_body = JSON.parse(request.body)
      fake_response
    end

    http_start = ->(*_args, &block) { block.call(fake_http) }
    Net::HTTP.stub(:start, http_start) do
      EvalOpsPrLensReview.call_anthropic(
        prompt: "Return JSON",
        model: "claude-opus-4-7",
        api_key: "test-key"
      )
    end

    assert_equal "claude-opus-4-7", request_body.fetch("model")
    refute_includes request_body.keys, "temperature"
  end

  def test_build_lens_prompt_includes_review_context
    pr_json = {
      "title" => "Risky workflow",
      "html_url" => "https://github.com/evalops/deploy/pull/1",
      "draft" => false,
      "base" => {
        "ref" => "main",
        "sha" => "base"
      },
      "head" => {
        "ref" => "branch",
        "sha" => "head"
      }
    }

    prompt = EvalOpsPrLensReview.build_lens_prompt(
      repo: "evalops/deploy",
      pr: 1,
      lens: "iam-blast-radius",
      pr_json: pr_json,
      file_summary: "modified\t.github/workflows/release.yml\t+10\t-2",
      review_context: "Inline review comments:\n- cursor .github/workflows/release.yml:42: token now has write-all",
      changed_files_text: "M\t.github/workflows/release.yml",
      diff_text: "@@ workflow diff @@",
      diff_truncated: false
    )

    assert_includes prompt, "Pull request context:"
    assert_includes prompt, "token now has write-all"
    assert_includes prompt, "Existing bot or human review comments are evidence"
  end

  def test_migration_safety_lens_covers_stateful_infra_rollouts
    pr_json = {
      "title" => "Buildfarm disk headroom",
      "html_url" => "https://github.com/evalops/deploy/pull/2",
      "draft" => false,
      "base" => {
        "ref" => "main",
        "sha" => "base"
      },
      "head" => {
        "ref" => "branch",
        "sha" => "head"
      }
    }

    prompt = EvalOpsPrLensReview.build_lens_prompt(
      repo: "evalops/deploy",
      pr: 2,
      lens: "migration-safety",
      pr_json: pr_json,
      file_summary: "modified\tinfrastructure/gcp/stacks/60-bazel-remote-execution/main.tf\t+20\t-5",
      review_context: "",
      changed_files_text: "M\tinfrastructure/gcp/stacks/60-bazel-remote-execution/main.tf",
      diff_text: "@@ terraform diff @@",
      diff_truncated: false
    )

    assert_includes prompt, "stateful infrastructure migrations"
    assert_includes prompt, "Terraform, startup scripts, disk/cache migrations"
    assert_includes prompt, "destructive filesystem or cloud-resource cleanup"
  end

  private

  def finding(title, confidence, priority, path, line)
    {
      "title" => title,
      "body" => "Body for #{title}",
      "confidence_score" => confidence,
      "priority" => priority,
      "code_location" => {
        "path" => path,
        "line" => line
      }
    }
  end
end
