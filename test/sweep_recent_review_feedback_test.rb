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
    assert_equal 2, first.fetch("finding_fingerprints").length
    assert_match(/\A[0-9a-f]{64}\z/, first.fetch("finding_fingerprints").first)
    assert_equal 1, first.fetch("repo_fingerprints").fetch("evalops/platform").length
    assert_equal "evalops/proto", first.fetch("repo_sample_findings").fetch("evalops/proto").first.fetch("repo")

    markdown = EvalOpsReviewFeedbackSweep.guardrail_backlog_markdown(backlog)
    assert_includes markdown, "# Review feedback guardrail backlog"
    assert_includes markdown, "| 1 | `generated-contract-drift` Generated contract drift | 140 | 2 | evalops/platform, evalops/proto |"
    assert_includes markdown, "<!-- evalops-review-feedback-guardrail-backlog -->"

    JSON.parse(JSON.pretty_generate(backlog))
  end

  def test_guardrail_backlog_keeps_security_secret_feedback_reachable
    security_class = EvalOpsReviewFeedbackSweep.guardrail_class(
      {
        "repo" => "evalops/fathom",
        "pr_title" => "notarization: configure credentials",
        "path" => "scripts/bootstrap-notary-credentials.py",
        "body_first_line" => "Credential secret can shadow the API key token",
        "feedback_class" => "review_thread",
        "kind" => "review_thread"
      }
    )
    config_class = EvalOpsReviewFeedbackSweep.guardrail_class(
      {
        "repo" => "evalops/deploy",
        "pr_title" => "deploy: validate k8s selector YAML",
        "path" => "k8s/ensemble/worker-deployment.yaml",
        "body_first_line" => "Kubernetes desired-state selector is not validated",
        "feedback_class" => "review_thread",
        "kind" => "review_thread"
      }
    )

    assert_equal "security-authz", security_class.fetch("key")
    assert_equal "configuration-safety", config_class.fetch("key")
  end

  def test_guardrail_backlog_classifies_parser_and_visual_capture_feedback
    parser_class = EvalOpsReviewFeedbackSweep.guardrail_class(
      {
        "repo" => "evalops/deploy",
        "pr_title" => "fix: harden Ensemble checksum guardrail parsing",
        "path" => nil,
        "body_first_line" => "Parse real CLI flags instead of substring matching",
        "feedback_class" => "top_level_pr_comment",
        "kind" => "pr_comment"
      }
    )
    visual_class = EvalOpsReviewFeedbackSweep.guardrail_class(
      {
        "repo" => "evalops/fathom",
        "pr_title" => "capture: add native perception provider",
        "path" => "macos/FathomCore/Sources/FathomCore/NativePerceptionProvider.swift",
        "body_first_line" => "Visual sampler error prevents entire frame capture",
        "feedback_class" => "review_thread",
        "kind" => "review_thread"
      }
    )

    assert_equal "parser-cli-contract", parser_class.fetch("key")
    assert_equal "visual-capture-resilience", visual_class.fetch("key")
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

  def test_guardrail_issue_title_and_body_are_stable_lifecycle_artifacts
    backlog = {
      "schema_version" => "evalops.review_feedback_guardrail_backlog.v1",
      "owner" => "evalops",
      "generated_at" => "2026-05-10T05:40:00Z",
      "merged_since" => "2026-04-10",
      "min_severity" => "high",
      "class_count" => 1,
      "classes" => [
        {
          "key" => "runtime-smoke-coverage",
          "title" => "Runtime smoke coverage gap",
          "score" => 100,
          "finding_count" => 2,
          "repo_count" => 1,
          "repos" => ["evalops/platform"],
          "recommended_guardrail" => "Add a smoke or preflight fixture that proves the runtime-visible behavior.",
          "sample_findings" => [
            {
              "repo" => "evalops/platform",
              "pr_number" => 1676,
              "feedback_url" => "https://github.com/evalops/platform/pull/1676#discussion_r1",
              "path" => "internal/agentruntime/agentruntime/postgres_store.go",
              "line" => 295,
              "severity" => "p1",
              "body_first_line" => "Roll back tx before loading idempotent receipt"
            }
          ]
        }
      ]
    }
    entry = backlog.fetch("classes").first

    assert_equal(
      "[codex] Guardrail backlog: Runtime smoke coverage gap (runtime-smoke-coverage)",
      EvalOpsReviewFeedbackSweep.guardrail_issue_title(entry)
    )

    body = EvalOpsReviewFeedbackSweep.guardrail_issue_body(backlog, entry)
    assert_includes body, "<!-- evalops-review-feedback-guardrail-issue:runtime-smoke-coverage -->"
    assert_includes body, "- Class: `runtime-smoke-coverage`"
    assert_includes body, "- Repos: `evalops/platform`"
    assert_includes body, "Roll back tx before loading idempotent receipt"
    assert_includes body, "## Finding fingerprints"
    assert_match(/- `[0-9a-f]{64}`/, body)
    assert_includes body, "The guardrail fails for at least one representative feedback shape listed above."
    assert_includes body, "The issue is closed only after the guardrail has merged"
  end

  def test_repo_guardrail_issue_title_and_body_route_feedback_to_source_repo
    finding = {
      "repo" => "evalops/platform",
      "pr_number" => 1676,
      "feedback_url" => "https://github.com/evalops/platform/pull/1676#discussion_r1",
      "path" => "internal/agentruntime/agentruntime/postgres_store.go",
      "line" => 295,
      "severity" => "p1",
      "body_first_line" => "Roll back tx before loading idempotent receipt"
    }
    fingerprint = EvalOpsReviewFeedbackSweep.guardrail_finding_fingerprint(finding)
    backlog = {
      "schema_version" => "evalops.review_feedback_guardrail_backlog.v1",
      "owner" => "evalops",
      "generated_at" => "2026-05-10T05:40:00Z",
      "merged_since" => "2026-04-10",
      "min_severity" => "high",
      "class_count" => 1
    }
    entry = {
      "key" => "runtime-smoke-coverage",
      "title" => "Runtime smoke coverage gap",
      "score" => 100,
      "finding_count" => 2,
      "repos" => ["evalops/platform"],
      "recommended_guardrail" => "Add a smoke or preflight fixture that proves the runtime-visible behavior.",
      "repo_fingerprints" => {
        "evalops/platform" => [fingerprint]
      },
      "repo_sample_findings" => {
        "evalops/platform" => [finding]
      },
      "sample_findings" => [finding]
    }

    assert_equal(
      "[codex] Guardrail candidate: Runtime smoke coverage gap (runtime-smoke-coverage)",
      EvalOpsReviewFeedbackSweep.repo_guardrail_issue_title(entry)
    )

    body = EvalOpsReviewFeedbackSweep.repo_guardrail_issue_body(
      backlog,
      entry,
      repo: "evalops/platform",
      org_issue_url: "https://github.com/evalops/.github/issues/49"
    )
    assert_includes body, "<!-- evalops-review-feedback-repo-guardrail-issue:runtime-smoke-coverage -->"
    assert_includes body, "- Repo: `evalops/platform`"
    assert_includes body, "- Org tracker: https://github.com/evalops/.github/issues/49"
    assert_includes body, "Representative feedback in this repo"
    assert_includes body, "Roll back tx before loading idempotent receipt"
    assert_includes body, "- `#{fingerprint}`"
  end

  def test_guardrail_lifecycle_json_records_issue_actions
    backlog = {
      "schema_version" => "evalops.review_feedback_guardrail_backlog.v1",
      "owner" => "evalops",
      "merged_since" => "2026-04-10",
      "min_severity" => "high",
      "class_count" => 1,
      "classes" => []
    }
    lifecycle = EvalOpsReviewFeedbackSweep.guardrail_lifecycle_json(
      backlog,
      issue_results: [
        {
          "class_key" => "runtime-smoke-coverage",
          "title" => "[codex] Guardrail backlog: Runtime smoke coverage gap (runtime-smoke-coverage)",
          "issue_number" => 49,
          "issue_url" => "https://github.com/evalops/.github/issues/49",
          "action" => "updated"
        }
      ],
      generated_at: Time.utc(2026, 5, 10, 5, 45, 0)
    )

    assert_equal "evalops.review_feedback_guardrail_lifecycle.v1", lifecycle.fetch("schema_version")
    assert_equal "evalops.review_feedback_guardrail_backlog.v1", lifecycle.fetch("source_schema_version")
    assert_equal "2026-05-10T05:45:00Z", lifecycle.fetch("generated_at")
    assert_equal 1, lifecycle.fetch("class_count")
    assert_equal 1, lifecycle.fetch("issue_count")
    assert_equal "updated", lifecycle.fetch("issues").first.fetch("action")

    JSON.parse(JSON.pretty_generate(lifecycle))
  end

  def test_issue_number_from_url_extracts_github_issue_number
    assert_equal 49, EvalOpsReviewFeedbackSweep.issue_number_from_url("https://github.com/evalops/.github/issues/49")
    assert_nil EvalOpsReviewFeedbackSweep.issue_number_from_url("https://github.com/evalops/.github/pull/49")
  end

  def test_guardrail_issue_key_from_title_extracts_stable_class_key
    assert_equal(
      "parser-cli-contract",
      EvalOpsReviewFeedbackSweep.guardrail_issue_key_from_title("[codex] Guardrail backlog: Parser and CLI contract drift (parser-cli-contract)")
    )
    assert_nil EvalOpsReviewFeedbackSweep.guardrail_issue_key_from_title("Parser and CLI contract drift (parser-cli-contract)")
  end

  def test_upsert_guardrail_class_issue_keeps_closed_issue_closed_when_fingerprints_match
    finding = {
      "repo" => "evalops/deploy",
      "pr_number" => 2390,
      "feedback_url" => "https://github.com/evalops/deploy/pull/2390#issuecomment-1",
      "path" => nil,
      "line" => nil,
      "severity" => "high",
      "body_sha256" => Digest::SHA256.hexdigest("Parse real CLI flags instead of substring matching"),
      "body_first_line" => "Parse real CLI flags instead of substring matching"
    }
    fingerprint = EvalOpsReviewFeedbackSweep.guardrail_finding_fingerprint(finding)
    backlog = {
      "generated_at" => "2026-05-10T05:40:00Z",
      "merged_since" => "2026-05-09T05:40:00Z",
      "min_severity" => "high",
      "classes" => []
    }
    entry = {
      "key" => "parser-cli-contract",
      "title" => "Parser and CLI contract drift",
      "score" => 80,
      "finding_count" => 1,
      "repos" => ["evalops/deploy"],
      "recommended_guardrail" => "Add parser-backed tests.",
      "finding_fingerprints" => [fingerprint],
      "sample_findings" => [finding]
    }
    issue = {
      "number" => 50,
      "title" => "[codex] Guardrail backlog: Parser and CLI contract drift (parser-cli-contract)",
      "state" => "CLOSED",
      "url" => "https://github.com/evalops/.github/issues/50",
      "body" => "- `#{fingerprint}`"
    }
    handler = lambda do |args, _input|
      if args[0, 2] == ["issue", "list"]
        [JSON.generate([issue]), "", success_status]
      else
        flunk("unexpected gh call: #{args.inspect}")
      end
    end

    result = nil
    calls = with_stubbed_gh(handler) do
      result = EvalOpsReviewFeedbackSweep.upsert_guardrail_class_issue(
        repo: "evalops/.github",
        backlog: backlog,
        entry: entry
      )
    end

    assert_equal "already_closed", result.fetch("action")
    assert_equal 50, result.fetch("issue_number")
    assert_equal 1, calls.length
  end

  def test_upsert_guardrail_class_issue_reopens_closed_issue_when_fingerprints_change
    finding = {
      "repo" => "evalops/deploy",
      "pr_number" => 2391,
      "feedback_url" => "https://github.com/evalops/deploy/pull/2391#issuecomment-1",
      "path" => "scripts/check.py",
      "line" => 17,
      "severity" => "high",
      "body_first_line" => "Parse command flags with the parser"
    }
    backlog = {
      "generated_at" => "2026-05-10T05:40:00Z",
      "merged_since" => "2026-05-09T05:40:00Z",
      "min_severity" => "high",
      "classes" => []
    }
    entry = {
      "key" => "parser-cli-contract",
      "title" => "Parser and CLI contract drift",
      "score" => 80,
      "finding_count" => 1,
      "repos" => ["evalops/deploy"],
      "recommended_guardrail" => "Add parser-backed tests.",
      "sample_findings" => [finding]
    }
    issue = {
      "number" => 50,
      "title" => "[codex] Guardrail backlog: Parser and CLI contract drift (parser-cli-contract)",
      "state" => "CLOSED",
      "url" => "https://github.com/evalops/.github/issues/50",
      "body" => "- `#{Digest::SHA256.hexdigest("old")}`"
    }
    handler = lambda do |args, input|
      if args[0, 2] == ["issue", "list"]
        [JSON.generate([issue]), "", success_status]
      elsif args[0, 3] == ["issue", "reopen", "50"]
        ["", "", success_status]
      elsif args[0, 3] == ["issue", "edit", "50"]
        assert_includes input, "## Finding fingerprints"
        ["", "", success_status]
      else
        flunk("unexpected gh call: #{args.inspect}")
      end
    end

    result = nil
    calls = with_stubbed_gh(handler) do
      result = EvalOpsReviewFeedbackSweep.upsert_guardrail_class_issue(
        repo: "evalops/.github",
        backlog: backlog,
        entry: entry
      )
    end

    assert_equal "reopened", result.fetch("action")
    assert_equal ["issue", "reopen", "50"], calls[1].first(3)
    assert_equal ["issue", "edit", "50"], calls[2].first(3)
  end

  def test_upsert_repo_guardrail_issue_keeps_closed_issue_closed_when_fingerprints_match
    finding = {
      "repo" => "evalops/deploy",
      "pr_number" => 2390,
      "feedback_url" => "https://github.com/evalops/deploy/pull/2390#issuecomment-1",
      "path" => nil,
      "line" => nil,
      "severity" => "high",
      "body_first_line" => "Parse real CLI flags instead of substring matching"
    }
    fingerprint = EvalOpsReviewFeedbackSweep.guardrail_finding_fingerprint(finding)
    backlog = {
      "generated_at" => "2026-05-10T05:40:00Z",
      "merged_since" => "2026-05-09T05:40:00Z",
      "min_severity" => "high"
    }
    entry = {
      "key" => "parser-cli-contract",
      "title" => "Parser and CLI contract drift",
      "score" => 80,
      "finding_count" => 1,
      "repos" => ["evalops/deploy"],
      "recommended_guardrail" => "Add parser-backed tests.",
      "repo_fingerprints" => {
        "evalops/deploy" => [fingerprint]
      },
      "repo_sample_findings" => {
        "evalops/deploy" => [finding]
      },
      "sample_findings" => [finding]
    }
    issue = {
      "number" => 2400,
      "title" => "[codex] Guardrail candidate: Parser and CLI contract drift (parser-cli-contract)",
      "state" => "CLOSED",
      "url" => "https://github.com/evalops/deploy/issues/2400",
      "body" => "- `#{fingerprint}`"
    }
    handler = lambda do |args, _input|
      if args[0, 2] == ["issue", "list"]
        assert_equal "evalops/deploy", args[args.index("--repo") + 1]
        [JSON.generate([issue]), "", success_status]
      else
        flunk("unexpected gh call: #{args.inspect}")
      end
    end

    result = nil
    calls = with_stubbed_gh(handler) do
      result = EvalOpsReviewFeedbackSweep.upsert_repo_guardrail_issue(
        repo: "evalops/deploy",
        backlog: backlog,
        entry: entry,
        org_issue_url: "https://github.com/evalops/.github/issues/50"
      )
    end

    assert_equal "repo", result.fetch("scope")
    assert_equal "evalops/deploy", result.fetch("repo")
    assert_equal "already_closed", result.fetch("action")
    assert_equal 1, calls.length
  end

  def test_upsert_repo_guardrail_issues_creates_one_issue_per_source_repo
    platform_finding = {
      "repo" => "evalops/platform",
      "pr_number" => 1545,
      "feedback_url" => "https://github.com/evalops/platform/pull/1545#discussion_r1",
      "path" => "proto/codex/v1/codex.proto",
      "line" => 42,
      "severity" => "p1",
      "body_first_line" => "generated TypeScript SDK is stale"
    }
    proto_finding = {
      "repo" => "evalops/proto",
      "pr_number" => 88,
      "feedback_url" => "https://github.com/evalops/proto/pull/88#discussion_r2",
      "path" => "gen/go/meter/v1/event.pb.go",
      "line" => 7,
      "severity" => "high",
      "body_first_line" => "generated Go output was not committed"
    }
    backlog = {
      "generated_at" => "2026-05-10T05:40:00Z",
      "merged_since" => "2026-04-10",
      "min_severity" => "high",
      "classes" => [
        {
          "key" => "generated-contract-drift",
          "title" => "Generated contract drift",
          "score" => 140,
          "finding_count" => 2,
          "repos" => ["evalops/platform", "evalops/proto"],
          "recommended_guardrail" => "Add generated-output drift checks.",
          "repo_sample_findings" => {
            "evalops/platform" => [platform_finding],
            "evalops/proto" => [proto_finding]
          },
          "sample_findings" => [platform_finding, proto_finding]
        }
      ]
    }
    created_urls = {
      "evalops/platform" => "https://github.com/evalops/platform/issues/1",
      "evalops/proto" => "https://github.com/evalops/proto/issues/2"
    }
    handler = lambda do |args, input|
      if args[0, 2] == ["issue", "list"]
        [JSON.generate([]), "", success_status]
      elsif args[0, 2] == ["issue", "create"]
        repo = args[args.index("--repo") + 1]
        assert_includes input, "https://github.com/evalops/.github/issues/77"
        [created_urls.fetch(repo), "", success_status]
      else
        flunk("unexpected gh call: #{args.inspect}")
      end
    end

    results = nil
    with_stubbed_gh(handler) do
      results = EvalOpsReviewFeedbackSweep.upsert_repo_guardrail_issues(
        backlog: backlog,
        org_issue_results: [
          {
            "class_key" => "generated-contract-drift",
            "issue_url" => "https://github.com/evalops/.github/issues/77"
          }
        ]
      )
    end

    assert_equal ["evalops/platform", "evalops/proto"], results.map { |result| result.fetch("repo") }
    assert_equal ["created", "created"], results.map { |result| result.fetch("action") }
  end

  def test_upsert_repo_guardrail_issues_skips_classes_already_closed_at_org_level
    backlog = {
      "classes" => [
        {
          "key" => "parser-cli-contract",
          "title" => "Parser and CLI contract drift",
          "repos" => ["evalops/deploy"],
          "sample_findings" => []
        }
      ]
    }

    results = nil
    with_stubbed_gh(lambda { |args, _input| flunk("unexpected gh call: #{args.inspect}") }) do
      results = EvalOpsReviewFeedbackSweep.upsert_repo_guardrail_issues(
        backlog: backlog,
        org_issue_results: [
          {
            "class_key" => "parser-cli-contract",
            "issue_url" => "https://github.com/evalops/.github/issues/50",
            "action" => "already_closed"
          }
        ]
      )
    end

    assert_equal [], results
  end

  def test_close_stale_guardrail_class_issues_closes_only_missing_classes
    backlog = {
      "classes" => [
        {
          "key" => "parser-cli-contract"
        }
      ]
    }
    list_payload = [
      {
        "number" => 48,
        "title" => "[codex] Guardrail backlog: Other feedback (other-feedback)",
        "url" => "https://github.com/evalops/.github/issues/48"
      },
      {
        "number" => 49,
        "title" => "[codex] Guardrail backlog: Parser and CLI contract drift (parser-cli-contract)",
        "url" => "https://github.com/evalops/.github/issues/49"
      }
    ]

    handler = lambda do |args, _input|
      if args[0, 2] == ["issue", "list"]
        [JSON.generate(list_payload), "", success_status]
      elsif args[0, 3] == ["issue", "close", "48"]
        ["", "", success_status]
      else
        flunk("unexpected gh call: #{args.inspect}")
      end
    end
    results = nil

    calls = with_stubbed_gh(handler) do
      results = EvalOpsReviewFeedbackSweep.close_stale_guardrail_class_issues(repo: "evalops/.github", backlog: backlog)
    end

    assert_equal 1, results.length
    assert_equal "other-feedback", results.first.fetch("class_key")
    assert_equal "closed_stale", results.first.fetch("action")
    assert_equal ["issue", "close", "48"], calls.last.first(3)
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

  private

  def success_status
    Object.new.tap do |status|
      def status.success?
        true
      end
    end
  end

  def with_stubbed_gh(handler)
    original = EvalOpsReviewFeedbackSweep.method(:gh)
    calls = []
    EvalOpsReviewFeedbackSweep.define_singleton_method(:gh) do |*args, input: nil|
      calls << args
      handler.call(args, input)
    end
    yield calls
    calls
  ensure
    EvalOpsReviewFeedbackSweep.define_singleton_method(:gh) do |*args, input: nil|
      original.call(*args, input: input)
    end
  end
end
