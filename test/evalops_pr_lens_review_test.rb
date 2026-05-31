# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
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

  def test_parse_pr_filter_accepts_bare_pr_number_for_single_repo_dispatch
    filter = EvalOpsPrLensReview.parse_pr_filter(
      "2023",
      repos: %w[evalops/platform]
    )

    assert_equal [2023], filter.fetch("evalops/platform")
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

  def test_matrix_for_uses_classified_lenses
    prs = [
      {
        "repo" => "evalops/deploy",
        "repo_slug" => "evalops-deploy",
        "number" => 10,
        "head_sha" => "head",
        "base_sha" => "base",
        "base_ref" => "main",
        "head_ref" => "branch",
        "lenses" => %w[iam-blast-radius argo-manifest-skew]
      }
    ]

    matrix = EvalOpsPrLensReview.matrix_for(prs)

    assert_equal %w[iam-blast-radius argo-manifest-skew], matrix.map { |row| row.fetch("lens") }
    assert_equal ["base"], matrix.map { |row| row.fetch("base_sha") }.uniq
  end

  def test_lenses_for_paths_selects_targeted_review_lenses
    lenses = EvalOpsPrLensReview.lenses_for_paths(
      [
        ".github/workflows/release.yml",
        "clusters/prod/kustomization.yaml",
        "proto/platform/v1/service.proto"
      ]
    )

    assert_includes lenses, "iam-blast-radius"
    assert_includes lenses, "argo-manifest-skew"
    assert_includes lenses, "nats-contract-drift"
    assert_includes lenses, "generated-sdk-delta"
    refute_includes lenses, "eval-regression-risk"
  end

  def test_lenses_for_paths_skips_docs_only_prs
    assert_empty EvalOpsPrLensReview.lenses_for_paths(["README.md", "docs/runbook.md"])
  end

  def test_review_context_helpers_scrub_invalid_utf8_bytes
    invalid = "comment \xC3 body".b

    section = EvalOpsPrLensReview.list_section("Inline review comments", ["  #{invalid}  "])
    snippet = EvalOpsPrLensReview.short_text(invalid, max_bytes: 10)

    assert_includes section, "comment"
    assert_predicate section, :valid_encoding?
    assert_includes snippet, "...[truncated]"
    assert_predicate snippet, :valid_encoding?
  end

  def test_discover_open_prs_can_force_lenses_for_explicit_review_requests
    pr = {
      "number" => 103,
      "title" => "Canary",
      "html_url" => "https://github.com/evalops/.github/pull/103",
      "draft" => false,
      "head" => { "sha" => "head", "ref" => "evalopsbot-review-canary" },
      "base" => { "sha" => "base", "ref" => "main" }
    }
    api = lambda do |path, **_kwargs|
      case path
      when "repos/evalops/.github/pulls?state=open&per_page=100"
        [pr]
      when "repos/evalops/.github/pulls/103/files?per_page=100"
        [{ "filename" => ".github/evalopsbot-canary/review-request.md" }]
      else
        flunk "unexpected gh api path #{path}"
      end
    end

    EvalOpsPrLensReview.stub(:gh_api_json, api) do
      prs = EvalOpsPrLensReview.discover_open_prs(
        repos: ["evalops/.github"],
        pr_filter: { "evalops/.github" => [103] },
        force_lenses: %w[migration-safety iam-blast-radius]
      )

      assert_equal %w[migration-safety iam-blast-radius], prs.fetch(0).fetch("lenses")
    end
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

  def test_dedupe_and_rank_merges_same_defect_across_nearby_lens_findings
    findings = [
      finding("Workflow token can write every repo", 0.91, 1, ".github/workflows/release.yml", 22).merge(
        "repo" => "evalops/deploy",
        "pr" => 10,
        "lens" => "iam-blast-radius",
        "head_sha" => "abc123",
        "check_id" => "evalops-pr-lens/iam-blast-radius"
      ),
      finding("Release workflow token writes every repository", 0.96, 1, ".github/workflows/release.yml", 24).merge(
        "repo" => "evalops/deploy",
        "pr" => 10,
        "lens" => "migration-safety",
        "head_sha" => "abc123",
        "check_id" => "evalops-pr-lens/migration-safety"
      )
    ]

    ranked = EvalOpsPrLensReview.dedupe_and_rank(findings)

    assert_equal 1, ranked.length
    assert_equal "Release workflow token writes every repository", ranked.fetch(0).fetch("title")
  end

  def test_post_status_also_attempts_check_run_without_breaking_status_publication
    calls = []
    ok = Object.new
    ok.define_singleton_method(:success?) { true }
    capture = lambda do |_env, *command, stdin_data: nil|
      calls << { command: command, stdin_data: stdin_data }
      if command.include?("check-runs?check_name=evalops-pr-lens%2Fmeta-review&per_page=100")
        [JSON.generate("check_runs" => []), "", ok]
      else
        ["{}", "", ok]
      end
    end

    Open3.stub(:capture3, capture) do
      EvalOpsPrLensReview.post_status(
        repo: "evalops/deploy",
        sha: "abc123",
        context: "evalops-pr-lens/meta-review",
        state: "success",
        description: "No high-confidence PR lens findings",
        target_url: "https://github.com/evalops/.github/actions/runs/1"
      )
    end

    assert calls.any? { |call| call.fetch(:command).include?("repos/evalops/deploy/statuses/abc123") }
    check_create = calls.find { |call| call.fetch(:command).include?("repos/evalops/deploy/check-runs") }
    assert check_create
    body = JSON.parse(check_create.fetch(:stdin_data))
    assert_equal "evalops-pr-lens/meta-review", body.fetch("name")
    assert_equal "completed", body.fetch("status")
    assert_equal "success", body.fetch("conclusion")
  end

  def test_github_app_jwt_uses_app_id_as_issuer
    key = OpenSSL::PKey::RSA.generate(2048)
    jwt = EvalOpsPrLensReview.github_app_jwt(app_id: "12345", private_key: key.to_pem, now: Time.utc(2026, 5, 20, 1, 2, 3))
    _header, payload, _signature = jwt.split(".")
    decoded = JSON.parse(Base64.urlsafe_decode64(payload + ("=" * ((4 - payload.length % 4) % 4))))

    assert_equal "12345", decoded.fetch("iss")
    assert_equal Time.utc(2026, 5, 20, 1, 1, 3).to_i, decoded.fetch("iat")
  end

  def test_lens_routing_config_overrides_default_review_options
    Dir.mktmpdir do |dir|
      config = File.join(dir, "routing.yml")
      File.write(
        config,
        <<~YAML
          defaults:
            provider: anthropic
            model: claude-opus-4-7
            max_diff_bytes: 180000
          lenses:
            generated-sdk-delta:
              model: claude-opus-4-7-generated
              max_diff_bytes: 260000
        YAML
      )

      options = EvalOpsPrLensReview.effective_review_options(
        lens: "generated-sdk-delta",
        provider: "openai",
        model: "gpt-5.2",
        max_diff_bytes: 1000,
        routing_config: config
      )

      assert_equal "anthropic", options.fetch(:provider)
      assert_equal "claude-opus-4-7-generated", options.fetch(:model)
      assert_equal 260000, options.fetch(:max_diff_bytes)
    end
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

  def test_gh_api_uses_input_flag_for_request_body
    captured = nil
    ok_status = Object.new
    ok_status.define_singleton_method(:success?) { true }
    capture = lambda do |env, *command, stdin_data: nil|
      captured = {
        env: env,
        command: command,
        stdin_data: stdin_data
      }
      ["{}", "", ok_status]
    end

    Open3.stub(:capture3, capture) do
      EvalOpsPrLensReview.gh_api(
        "--method",
        "POST",
        "repos/evalops/.github/issues/1/comments",
        input: JSON.generate(body: "hello"),
        token: "test-token"
      )
    end

    assert_equal "test-token", captured.fetch(:env).fetch("GH_TOKEN")
    assert_equal(
      ["gh", "api", "--method", "POST", "repos/evalops/.github/issues/1/comments", "--input", "-"],
      captured.fetch(:command)
    )
    assert_equal "{\"body\":\"hello\"}", captured.fetch(:stdin_data)
  end

  def test_normalize_search_pull_requests_dedupes_review_requests
    rows = [
      {
        "repository" => { "nameWithOwner" => "evalops/deploy" },
        "number" => 3511,
        "title" => "Runtime rollout aliases",
        "url" => "https://github.com/evalops/deploy/pull/3511",
        "isDraft" => false,
        "updatedAt" => "2026-05-17T22:46:41Z"
      },
      {
        "repository" => { "nameWithOwner" => "evalops/deploy" },
        "number" => 3511,
        "title" => "Duplicate search row",
        "url" => "https://github.com/evalops/deploy/pull/3511",
        "isDraft" => false
      }
    ]

    prs = EvalOpsPrLensReview.normalize_search_pull_requests(rows)

    assert_equal 1, prs.length
    assert_equal "evalops/deploy", prs.fetch(0).fetch("repo")
    assert_equal "evalops-deploy", prs.fetch(0).fetch("repo_slug")
    assert_equal 3511, prs.fetch(0).fetch("number")
  end

  def test_review_started_for_head_uses_meta_review_status_context
    api = lambda do |*_args, **_kwargs|
      {
        "statuses" => [
          { "context" => "evalops-pr-lens/migration-safety" },
          { "context" => EvalOpsPrLensReview.meta_context }
        ]
      }
    end

    EvalOpsPrLensReview.stub(:gh_api_json, api) do
      assert EvalOpsPrLensReview.review_started_for_head?(repo: "evalops/deploy", head_sha: "abc123")
    end
  end

  def test_dispatch_requested_reviews_queues_and_marks_pending
    candidate = {
      "repo" => "evalops/deploy",
      "repo_slug" => "evalops-deploy",
      "number" => 3511,
      "title" => "Runtime rollout aliases",
      "url" => "https://github.com/evalops/deploy/pull/3511",
      "draft" => false
    }
    dispatched = []
    marked = []

    EvalOpsPrLensReview.stub(:review_requested_prs, ->(**_kwargs) { [candidate] }) do
      EvalOpsPrLensReview.stub(:pr_head_sha, ->(**_kwargs) { "abc123" }) do
        EvalOpsPrLensReview.stub(:review_started_for_head?, ->(**_kwargs) { false }) do
          EvalOpsPrLensReview.stub(:dispatch_review_requested, ->(**kwargs) { dispatched << kwargs }) do
            EvalOpsPrLensReview.stub(:mark_review_queued, ->(**kwargs) { marked << kwargs }) do
              result = EvalOpsPrLensReview.dispatch_requested_reviews(
                owner: "evalops",
                reviewer: "EvalOpsBot",
                limit: 100,
                dry_run: false,
                target_url: "https://github.com/evalops/.github/actions/runs/1"
              )

              assert_equal 1, result.fetch("dispatched_count")
              assert_equal [{ repo: "evalops/deploy", pr: 3511, requested_reviewer: "EvalOpsBot" }], dispatched
              assert_equal "abc123", marked.fetch(0).fetch(:head_sha)
            end
          end
        end
      end
    end
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

  def test_lens_workflow_checks_out_pull_request_head_ref
    workflow = File.read(File.expand_path("../.github/workflows/evalops-pr-lens-review.yml", __dir__))

    assert_includes workflow, "Prepare target pull request head"
    assert_includes workflow, "prepare-workspace"
    refute_includes workflow, 'ref: refs/pull/${{ matrix.pr }}/merge'
  end

  def test_prepare_workspace_writes_skipped_review_when_head_changes
    Dir.mktmpdir do |dir|
      output = File.join(dir, "lens-review.json")
      github_output = File.join(dir, "github-output")
      pr_json = {
        "state" => "open",
        "head" => { "sha" => "new-head" },
        "base" => { "sha" => "base", "ref" => "main" }
      }

      EvalOpsPrLensReview.stub(:pr_metadata, ->(**_kwargs) { pr_json }) do
        result = EvalOpsPrLensReview.prepare_workspace(
          repo: "evalops/deploy",
          pr: 10,
          lens: "iam-blast-radius",
          workspace: File.join(dir, "target"),
          output: output,
          github_output: github_output,
          snapshot_head_sha: "old-head",
          snapshot_base_sha: "base",
          token: nil
        )

        review = JSON.parse(File.read(output))
        assert_equal true, result.fetch("skip")
        assert_equal "skipped", review.fetch("status")
        assert_equal "pull request head changed since discovery", review.fetch("skip_reason")
        assert_includes File.read(github_output), "skip=true"
      end
    end
  end

  def test_meta_review_marks_incomplete_coverage_when_expected_lens_artifact_is_missing
    Dir.mktmpdir do |dir|
      discovery_dir = File.join(dir, "pr-lens-discovery")
      review_dir = File.join(dir, "pr-lens-evalops-deploy-10-iam-blast-radius")
      FileUtils.mkdir_p(discovery_dir)
      FileUtils.mkdir_p(review_dir)
      File.write(
        File.join(discovery_dir, "pr-lens-targets.json"),
        JSON.pretty_generate(
          [
            {
              "repo" => "evalops/deploy",
              "number" => 10,
              "head_sha" => "head",
              "lenses" => %w[iam-blast-radius argo-manifest-skew]
            }
          ]
        )
      )
      File.write(
        File.join(review_dir, "lens-review.json"),
        JSON.pretty_generate(
          {
            "schema_version" => 1,
            "repo" => "evalops/deploy",
            "pr" => 10,
            "lens" => "iam-blast-radius",
            "check_id" => "evalops-pr-lens/iam-blast-radius",
            "head_sha" => "head",
            "findings" => []
          }
        )
      )
      statuses = []

      EvalOpsPrLensReview.stub(:run_url, "https://github.com/evalops/.github/actions/runs/1") do
        EvalOpsPrLensReview.stub(:delete_marker_comments, ->(**_kwargs) {}) do
          EvalOpsPrLensReview.stub(:post_status, ->(**kwargs) { statuses << kwargs }) do
            result = EvalOpsPrLensReview.meta_review(
              artifact_root: dir,
              min_confidence: 0.82,
              output: File.join(dir, "meta-review.json")
            )

            assert_equal 2, result.fetch("expected_reviews")
            assert_equal 1, result.fetch("coverage").fetch(0).fetch("missing")
            assert_equal "error", statuses.fetch(0).fetch(:state)
            assert_includes statuses.fetch(0).fetch(:description), "coverage incomplete"
          end
        end
      end
    end
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
