#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "time"
require "uri"

module EvalOpsPrLensReview
  TARGET_REPOS = %w[
    evalops/platform
    evalops/deploy
    evalops/maestro-internal
  ].freeze

  LENSES = {
    "migration-safety" => {
      name: "Migration safety",
      focus: [
        "database migrations, schema ownership manifests, generated migration embeds, and stateful infrastructure migrations",
        "Terraform, startup scripts, disk/cache migrations, and one-time data cleanup that must be safe on fresh and existing resources",
        "backward/forward compatibility during rolling deploys, branch promotion, and rollback",
        "concurrent migration hazards, idempotency, destructive DDL, and destructive filesystem or cloud-resource cleanup",
        "missing migration tests, dry-runs, live plans, or release-order constraints"
      ]
    },
    "nats-contract-drift" => {
      name: "NATS contract drift",
      focus: [
        "NATS subjects, JetStream streams, consumers, queue groups, and retention policy changes",
        "protobuf, JSON schema, event catalog, or publisher/subscriber contract drift",
        "trace/context propagation across event boundaries",
        "missing local simulation, contract fixtures, or consumer compatibility coverage"
      ]
    },
    "argo-manifest-skew" => {
      name: "Argo manifest skew",
      focus: [
        "GitOps desired state, Helm values, Kustomize overlays, and ArgoCD application drift",
        "image tag policy, namespace/resource quota skew, and environment-specific values",
        "manifest references to missing ConfigMaps, Secrets, services, or CRDs",
        "changes that require deploy ordering or post-merge live-state verification"
      ]
    },
    "iam-blast-radius" => {
      name: "IAM blast radius",
      focus: [
        "GitHub Actions permissions, tokens, OIDC trust, cloud IAM roles, and service accounts",
        "secret handling, Vault/ExternalSecrets references, and credential exposure",
        "privilege expansion hidden in workflow, Terraform, Kubernetes, or app auth changes",
        "tenant or customer boundary regressions"
      ]
    },
    "generated-sdk-delta" => {
      name: "Generated SDK delta",
      focus: [
        "protobuf, OpenAPI, JSON schema, BigQuery schema, and generated TypeScript/Go/Python SDK drift",
        "release manifest, package version, changelog, and generated artifact consistency",
        "manual edits to generated files without generator or source contract updates",
        "missing generator commands or SDK publish compatibility checks"
      ]
    },
    "eval-regression-risk" => {
      name: "Eval regression risk",
      focus: [
        "evaluation datasets, golden fixtures, prompt/judge changes, scoring, and quality gates",
        "frontier model/provider changes, fallback behavior, and tenant-visible AI behavior",
        "regression budgets, flaky evals, missing smoke coverage, and false-pass risks",
        "operator/customer-facing behavior that should have an eval or scenario replay"
      ]
    }
  }.freeze

  LENS_PATH_RULES = {
    "migration-safety" => [
      %r{\A(db|database|migrations?)/}i,
      %r{migrations?/}i,
      %r{\.(sql|tf)\z}i,
      %r{\A(infrastructure|terraform|helm|charts|k8s|clusters)/}i,
      %r{(disk|cache|state|cleanup|backfill|bootstrap|startup)}i
    ],
    "nats-contract-drift" => [
      %r{(^|/)(nats|jetstream|streams?|consumers?|subjects?)(/|\.)}i,
      %r{(^|/)(proto|protos|protobuf|schemas?)/}i,
      %r{\.(proto|avsc)\z}i,
      %r{(cloudevents?|event[-_ ]?catalog|publisher|subscriber)}i
    ],
    "argo-manifest-skew" => [
      %r{\A(argocd|argo|clusters|k8s|kubernetes|overlays|base|helm|charts)/}i,
      %r{(^|/)(kustomization|values)\.ya?ml\z}i,
      %r{(^|/)applications?/}i,
      %r{(^|/)(deployment|service|configmap|secret|externalsecret|namespace|ingress)\.ya?ml\z}i
    ],
    "iam-blast-radius" => [
      %r{\A\.github/workflows/}i,
      %r{(^|/)(iam|rbac|serviceaccount|service-account|policy|permissions?)(/|\.)}i,
      %r{(^|/)(secrets?|external-secrets?|vault|oidc)(/|\.)}i,
      %r{\.(tf|tfvars)\z}i,
      %r{(token|credential|workload[-_ ]?identity|rolebinding|clusterrole)}i
    ],
    "generated-sdk-delta" => [
      %r{(^|/)(gen|generated|sdk|openapi|swagger|proto|protos|protobuf|schemas?)/}i,
      %r{\.(proto|openapi\.ya?ml|swagger\.json|schema\.json)\z}i,
      %r{(^|/)(package\.json|pyproject\.toml|go\.mod|buf\.yaml|buf\.gen\.yaml)\z}i,
      %r{(^|/)(CHANGELOG|release-please-config|\.release-please-manifest)}i
    ],
    "eval-regression-risk" => [
      %r{(^|/)(evals?|evaluations?|fixtures?|datasets?|goldens?|scenarios?|judges?|prompts?)/}i,
      %r{(^|/)(prompt|judge|rubric|score|scoring|golden|fixture)}i,
      %r{(^|/)testdata/}i
    ]
  }.freeze

  DOC_ONLY_PATH = %r{\A(README|SECURITY|CONTRIBUTING|CHANGELOG|docs/|profile/|.*\.(md|mdx|txt))}i

  MARKER = "<!-- evalops-pr-lens-review -->"
  REVIEW_REQUESTED_DISPATCH_EVENT = "evalopsbot-review-requested"
  REVIEW_REQUESTED_DISPATCH_SOURCE = "evalopsbot-review-request-dispatch"
  DEFAULT_MIN_CONFIDENCE = 0.82
  DEFAULT_MODEL = "claude-opus-4-7"
  DEFAULT_MAX_DIFF_BYTES = 180_000
  MAX_FINDINGS_PER_COMMENT = 12
  MAX_CONTEXT_ITEMS = 25

  module_function

  def parse_list(value)
    value.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  def normalize_repo(repo)
    raw = repo.to_s.strip
    return raw if raw.include?("/")

    "evalops/#{raw}"
  end

  def parse_pr_filter(value, repos:)
    entries = parse_list(value)
    return nil if entries.empty?

    normalized_repos = repos.map { |repo| normalize_repo(repo) }
    entries.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |entry, filter|
      if entry.include?("#")
        repo, number = entry.split("#", 2)
        filter[normalize_repo(repo)] << Integer(number)
      elsif normalized_repos.length == 1
        filter[normalized_repos.fetch(0)] << Integer(entry)
      else
        raise ArgumentError, "target_prs entries without repo require exactly one target repo: #{entry}"
      end
    end.transform_values(&:uniq)
  end

  def check_context(lens)
    "evalops-pr-lens/#{lens}"
  end

  def meta_context
    "evalops-pr-lens/meta-review"
  end

  def valid_lens!(lens)
    return lens if LENSES.key?(lens)

    raise ArgumentError, "unknown lens #{lens.inspect}; expected one of #{LENSES.keys.join(", ")}"
  end

  def lens_reason_for_path(path)
    LENS_PATH_RULES.each do |lens, patterns|
      return lens if patterns.any? { |pattern| path.match?(pattern) }
    end
    nil
  end

  def lenses_for_paths(paths)
    normalized = paths.map(&:to_s).map(&:strip).reject(&:empty?)
    return LENSES.keys if normalized.empty?

    lenses = normalized.flat_map do |path|
      LENS_PATH_RULES.each_with_object([]) do |(lens, patterns), matches|
        matches << lens if patterns.any? { |pattern| path.match?(pattern) }
      end
    end.uniq
    return lenses if lenses.any?
    return [] if normalized.all? { |path| path.match?(DOC_ONLY_PATH) }

    ["eval-regression-risk"]
  end

  def gh_api(*args, input: nil, token: ENV["GH_TOKEN"])
    env = {}
    env["GH_TOKEN"] = token if token && !token.empty?
    command = ["gh", "api", *args]

    if input
      command += ["--input", "-"]
      stdout, stderr, status = Open3.capture3(env, *command, stdin_data: input)
    else
      stdout, stderr, status = Open3.capture3(env, *command)
    end

    unless status.success?
      raise "gh api #{args.join(" ")} failed: #{stderr.empty? ? stdout : stderr}"
    end

    stdout
  end

  def gh_api_json(*args, input: nil, token: ENV["GH_TOKEN"])
    raw = gh_api(*args, input: input, token: token)
    return nil if raw.strip.empty?

    JSON.parse(raw)
  end

  def gh_search_review_requested(owner:, reviewer:, limit:, token: ENV["GH_TOKEN"])
    env = {}
    env["GH_TOKEN"] = token if token && !token.empty?
    command = [
      "gh", "search", "prs",
      "--owner", owner,
      "--review-requested", reviewer,
      "--state", "open",
      "--json", "repository,number,title,url,isDraft,updatedAt",
      "--limit", limit.to_s
    ]
    stdout, stderr, status = Open3.capture3(env, *command)
    unless status.success?
      raise "gh search prs failed: #{stderr.empty? ? stdout : stderr}"
    end

    JSON.parse(stdout)
  end

  def normalize_search_pull_requests(rows)
    rows.map do |row|
      repo = row.dig("repository", "nameWithOwner")
      next if repo.to_s.empty?

      {
        "repo" => normalize_repo(repo),
        "repo_slug" => normalize_repo(repo).tr("/", "-"),
        "number" => Integer(row.fetch("number")),
        "title" => row.fetch("title", ""),
        "url" => row.fetch("url", ""),
        "draft" => !!row["isDraft"],
        "updated_at" => row.fetch("updatedAt", nil)
      }
    rescue ArgumentError, KeyError, TypeError
      nil
    end.compact.uniq { |pr| [pr.fetch("repo"), pr.fetch("number")] }
  end

  def review_requested_prs(owner:, reviewer:, limit:)
    normalize_search_pull_requests(
      gh_search_review_requested(owner: owner, reviewer: reviewer, limit: limit)
    )
  end

  def pr_head_sha(repo:, pr:)
    pr_metadata(repo: repo, pr: pr).fetch("head").fetch("sha")
  end

  def pr_status_contexts(repo:, head_sha:)
    status = gh_api_json("repos/#{repo}/commits/#{head_sha}/status")
    Array(status.fetch("statuses", [])).map { |row| row.fetch("context", "") }
  end

  def review_started_for_head?(repo:, head_sha:)
    pr_status_contexts(repo: repo, head_sha: head_sha).include?(meta_context)
  end

  def dispatch_review_requested(repo:, pr:, requested_reviewer:)
    payload = {
      event_type: REVIEW_REQUESTED_DISPATCH_EVENT,
      client_payload: {
        target_repo: repo,
        target_pr: "#{repo}##{pr}",
        requested_reviewer: requested_reviewer,
        source: REVIEW_REQUESTED_DISPATCH_SOURCE
      }
    }
    gh_api("--method", "POST", "repos/evalops/.github/dispatches", input: JSON.generate(payload))
  end

  def mark_review_queued(repo:, head_sha:, target_url:)
    post_status(
      repo: repo,
      sha: head_sha,
      context: meta_context,
      state: "pending",
      description: "Queued EvalOpsBot requested deep review",
      target_url: target_url
    )
  end

  def dispatch_requested_reviews(owner:, reviewer:, limit:, dry_run:, target_url:, output: nil)
    candidates = review_requested_prs(owner: owner, reviewer: reviewer, limit: limit)
    results = candidates.map do |candidate|
      repo = candidate.fetch("repo")
      pr = candidate.fetch("number")
      head_sha = pr_head_sha(repo: repo, pr: pr)
      row = candidate.merge("head_sha" => head_sha)

      if review_started_for_head?(repo: repo, head_sha: head_sha)
        row.merge("action" => "skipped", "reason" => "review already queued or completed for head sha")
      elsif dry_run
        row.merge("action" => "would_dispatch")
      else
        dispatch_review_requested(repo: repo, pr: pr, requested_reviewer: reviewer)
        mark_review_queued(repo: repo, head_sha: head_sha, target_url: target_url)
        row.merge("action" => "dispatched")
      end
    end

    summary = {
      "schema_version" => 1,
      "generated_at" => Time.now.utc.iso8601,
      "owner" => owner,
      "requested_reviewer" => reviewer,
      "dry_run" => dry_run,
      "candidate_count" => candidates.length,
      "dispatched_count" => results.count { |row| row.fetch("action") == "dispatched" },
      "skipped_count" => results.count { |row| row.fetch("action") == "skipped" },
      "results" => results
    }
    File.write(output, JSON.pretty_generate(summary)) if output
    summary
  end

  def pr_files_metadata(repo:, pr:)
    gh_api_json("repos/#{repo}/pulls/#{pr}/files?per_page=100")
  end

  def discover_open_prs(repos:, pr_filter: nil)
    repos.flat_map do |repo|
      normalized_repo = normalize_repo(repo)
      prs = gh_api_json("repos/#{normalized_repo}/pulls?state=open&per_page=100")
      prs.select! { |pr| pr_filter.fetch(normalized_repo, []).include?(Integer(pr.fetch("number"))) } if pr_filter
      prs.map do |pr|
        files = pr_files_metadata(repo: normalized_repo, pr: Integer(pr.fetch("number")))
        filenames = files.map { |file| file.fetch("filename") }
        lenses = lenses_for_paths(filenames)
        {
          "repo" => normalized_repo,
          "repo_slug" => normalized_repo.tr("/", "-"),
          "number" => Integer(pr.fetch("number")),
          "title" => pr.fetch("title"),
          "url" => pr.fetch("html_url"),
          "draft" => !!pr.fetch("draft"),
          "head_sha" => pr.fetch("head").fetch("sha"),
          "base_sha" => pr.fetch("base").fetch("sha"),
          "base_ref" => pr.fetch("base").fetch("ref"),
          "head_ref" => pr.fetch("head").fetch("ref"),
          "changed_files" => filenames,
          "lenses" => lenses
        }
      end
    end
  end

  def matrix_for(prs, lenses: LENSES.keys)
    prs.flat_map do |pr|
      pr_lenses = pr.fetch("lenses", lenses)
      pr_lenses.map do |lens|
        valid_lens!(lens)
        {
          "repo" => pr.fetch("repo"),
          "repo_slug" => pr.fetch("repo_slug"),
          "pr" => pr.fetch("number"),
          "lens" => lens,
          "check_context" => check_context(lens),
          "head_sha" => pr.fetch("head_sha"),
          "base_sha" => pr.fetch("base_sha", nil),
          "base_ref" => pr.fetch("base_ref", nil),
          "head_ref" => pr.fetch("head_ref", nil)
        }
      end
    end
  end

  def write_github_outputs(path, outputs)
    return if path.to_s.empty?

    File.open(path, "a") do |file|
      outputs.each do |key, value|
        file.puts("#{key}=#{value}")
      end
    end
  end

  def post_status(repo:, sha:, context:, state:, description:, target_url: nil)
    fields = [
      "-f", "state=#{state}",
      "-f", "context=#{context}",
      "-f", "description=#{description.to_s[0, 140]}"
    ]
    fields += ["-f", "target_url=#{target_url}"] if target_url && !target_url.empty?

    gh_api("--method", "POST", "repos/#{repo}/statuses/#{sha}", *fields)
  end

  def write_json(path, payload)
    File.write(path, JSON.pretty_generate(payload))
    payload
  end

  def skipped_lens_review(repo:, pr:, lens:, head_sha:, reason:, output:)
    write_json(
      output,
      {
        "schema_version" => 1,
        "repo" => repo,
        "pr" => Integer(pr),
        "lens" => lens,
        "check_id" => check_context(lens),
        "head_sha" => head_sha.to_s,
        "generated_at" => Time.now.utc.iso8601,
        "status" => "skipped",
        "skip_reason" => reason,
        "summary" => "Skipped #{lens} lens review: #{reason}",
        "confidence_score" => 0.0,
        "findings" => []
      }
    )
  end

  def write_prepare_outputs(path, outputs)
    write_github_outputs(path, outputs)
  end

  def git_authorization_header(token)
    return nil if token.to_s.empty?

    "AUTHORIZATION: basic #{Base64.strict_encode64("x-access-token:#{token}")}"
  end

  def git_capture_auth(workspace, *args, token: nil)
    env = { "GIT_TERMINAL_PROMPT" => "0" }
    command = ["git"]
    command += ["-C", workspace] if workspace
    header = git_authorization_header(token)
    command += ["-c", "http.https://github.com/.extraheader=#{header}"] if header
    command += args

    stdout, stderr, status = Open3.capture3(env, *command)
    raise "git #{args.join(" ")} failed: #{stderr.empty? ? stdout : stderr}" unless status.success?

    stdout
  end

  def git_capture(workspace, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", workspace, *args)
    raise "git #{args.join(" ")} failed: #{stderr}" unless status.success?

    stdout
  end

  def prepare_workspace(repo:, pr:, lens:, workspace:, output:, github_output:, snapshot_head_sha:, snapshot_base_sha:, token:)
    head_sha = snapshot_head_sha.to_s
    begin
      pr_json = pr_metadata(repo: repo, pr: pr)
      current_state = pr_json.fetch("state", "").downcase
      current_head_sha = pr_json.fetch("head").fetch("sha")
      current_base_sha = pr_json.fetch("base").fetch("sha")
      base_ref = pr_json.fetch("base").fetch("ref")
      reason = nil

      if current_state != "open"
        reason = "pull request is #{current_state.empty? ? "not open" : current_state}"
      elsif !snapshot_head_sha.to_s.empty? && current_head_sha != snapshot_head_sha
        reason = "pull request head changed since discovery"
      elsif !snapshot_base_sha.to_s.empty? && current_base_sha != snapshot_base_sha
        reason = "pull request base changed since discovery"
      end

      if reason
        skipped_lens_review(repo: repo, pr: pr, lens: lens, head_sha: head_sha.empty? ? current_head_sha : head_sha, reason: reason, output: output)
        write_prepare_outputs(
          github_output,
          "skip" => "true",
          "skip_reason" => reason,
          "head_sha" => head_sha.empty? ? current_head_sha : head_sha,
          "base_sha" => snapshot_base_sha.to_s.empty? ? current_base_sha : snapshot_base_sha
        )
        return { "skip" => true, "reason" => reason }
      end

      FileUtils.rm_rf(workspace)
      FileUtils.mkdir_p(workspace)
      git_capture_auth(nil, "init", workspace, token: token)
      git_capture_auth(workspace, "remote", "add", "origin", "https://github.com/#{repo}.git", token: token)
      git_capture_auth(workspace, "fetch", "--no-tags", "origin", base_ref, "+refs/pull/#{pr}/head:refs/remotes/pull/#{pr}/head", token: token)
      git_capture_auth(workspace, "checkout", "--detach", current_head_sha, token: token)

      checked_out = git_capture_auth(workspace, "rev-parse", "HEAD", token: token).strip
      if checked_out != current_head_sha
        raise "checked out #{checked_out}, expected #{current_head_sha}"
      end

      write_prepare_outputs(
        github_output,
        "skip" => "false",
        "skip_reason" => "",
        "base_ref" => base_ref,
        "base_sha" => current_base_sha,
        "head_sha" => current_head_sha
      )
      {
        "skip" => false,
        "base_ref" => base_ref,
        "base_sha" => current_base_sha,
        "head_sha" => current_head_sha
      }
    rescue StandardError => e
      reason = "target ref unavailable: #{e.message.lines.first.to_s.strip}"
      skipped_lens_review(repo: repo, pr: pr, lens: lens, head_sha: head_sha, reason: reason, output: output)
      write_prepare_outputs(
        github_output,
        "skip" => "true",
        "skip_reason" => reason,
        "head_sha" => head_sha,
        "base_sha" => snapshot_base_sha.to_s
      )
      { "skip" => true, "reason" => reason }
    end
  end

  def truncated(text, max_bytes)
    raw = text.to_s
    return [raw, false] if raw.bytesize <= max_bytes

    [raw.byteslice(0, max_bytes).to_s, true]
  end

  def git_diff(workspace:, base_sha:, head_sha:, max_bytes:)
    diff = git_capture(workspace, "--no-pager", "diff", "--unified=5", "--no-ext-diff", base_sha, head_sha)
    truncated(diff, max_bytes)
  end

  def changed_files(workspace:, base_sha:, head_sha:)
    git_capture(workspace, "--no-pager", "diff", "--name-status", base_sha, head_sha)
  end

  def pr_metadata(repo:, pr:)
    gh_api_json("repos/#{repo}/pulls/#{pr}")
  end

  def pr_file_summary(repo:, pr:)
    files = gh_api_json("repos/#{repo}/pulls/#{pr}/files?per_page=100")
    files.map do |file|
      [
        file.fetch("status"),
        file.fetch("filename"),
        "+#{file.fetch("additions")}",
        "-#{file.fetch("deletions")}"
      ].join("\t")
    end.join("\n")
  end

  def short_text(value, max_bytes: 1_500)
    text = value.to_s.strip
    return "" if text.empty?
    return text if text.bytesize <= max_bytes

    "#{text.byteslice(0, max_bytes)}\n...[truncated]"
  end

  def list_section(title, rows)
    body = rows.compact.map(&:strip).reject(&:empty?)
    return "#{title}:\n(none)" if body.empty?

    "#{title}:\n#{body.first(MAX_CONTEXT_ITEMS).join("\n")}"
  end

  def pr_review_context(repo:, pr:, pr_json:, head_sha:)
    issue_comments = gh_api_json("repos/#{repo}/issues/#{pr}/comments?per_page=100")
    reviews = gh_api_json("repos/#{repo}/pulls/#{pr}/reviews?per_page=100")
    review_comments = gh_api_json("repos/#{repo}/pulls/#{pr}/comments?per_page=100")
    check_runs = gh_api_json("repos/#{repo}/commits/#{head_sha}/check-runs?per_page=100").fetch("check_runs", [])
    combined_status = gh_api_json("repos/#{repo}/commits/#{head_sha}/status")

    comments = issue_comments.last(MAX_CONTEXT_ITEMS).map do |comment|
      "- #{comment.dig("user", "login")} at #{comment.fetch("created_at", "")}: #{short_text(comment["body"], max_bytes: 900)}"
    end
    review_rows = reviews.last(MAX_CONTEXT_ITEMS).map do |review|
      body = short_text(review["body"], max_bytes: 900)
      "- #{review.dig("user", "login")} #{review.fetch("state", "")} at #{review.fetch("submitted_at", "")}: #{body.empty? ? "(no body)" : body}"
    end
    inline_rows = review_comments.last(MAX_CONTEXT_ITEMS).map do |comment|
      line = comment["line"] || comment["original_line"] || "?"
      "- #{comment.dig("user", "login")} #{comment.fetch("path", "unknown")}:#{line}: #{short_text(comment["body"], max_bytes: 900)}"
    end
    check_rows = check_runs.select do |check|
      !%w[success skipped neutral].include?(check["conclusion"].to_s.downcase)
    end.map do |check|
      "- check-run #{check.fetch("name", "unknown")}: status=#{check.fetch("status", "")} conclusion=#{check["conclusion"] || "pending"}"
    end
    status_rows = Array(combined_status["statuses"]).select do |status|
      status["state"].to_s != "success"
    end.map do |status|
      "- status #{status.fetch("context", "unknown")}: state=#{status.fetch("state", "")} description=#{status["description"]}"
    end

    [
      "Pull request body:\n#{short_text(pr_json["body"], max_bytes: 2_500).empty? ? "(none)" : short_text(pr_json["body"], max_bytes: 2_500)}",
      list_section("Issue comments", comments),
      list_section("PR review bodies", review_rows),
      list_section("Inline review comments", inline_rows),
      list_section("Non-green checks and statuses", check_rows + status_rows)
    ].join("\n\n")
  end

  def build_lens_prompt(repo:, pr:, lens:, pr_json:, file_summary:, review_context:, changed_files_text:, diff_text:, diff_truncated:)
    lens_config = LENSES.fetch(valid_lens!(lens))
    <<~PROMPT
      You are reviewing an EvalOps pull request through one narrow lens: #{lens_config.fetch(:name)}.

      Repository: #{repo}
      Pull request: ##{pr} #{pr_json.fetch("title")}
      URL: #{pr_json.fetch("html_url")}
      Base: #{pr_json.fetch("base").fetch("ref")} #{pr_json.fetch("base").fetch("sha")}
      Head: #{pr_json.fetch("head").fetch("ref")} #{pr_json.fetch("head").fetch("sha")}
      Draft: #{pr_json.fetch("draft")}

      Lens focus:
      #{lens_config.fetch(:focus).map { |item| "- #{item}" }.join("\n")}

      Rules:
      - Return JSON only. No markdown fences.
      - Report only actionable defects introduced by this PR that fit the lens.
      - Prefer no finding over a speculative finding.
      - Confidence must reflect direct evidence from the diff or live PR metadata.
      - Existing bot or human review comments are evidence, but verify them
        against the diff before turning them into a finding.
      - Use head-side file paths and line numbers where possible.
      - If no high-signal finding exists, return an empty findings array.
      - Do not ask for broad architecture redesigns, style-only changes, or unrelated cleanup.

      JSON shape:
      {
        "summary": "short lens summary",
        "confidence_score": 0.0,
        "findings": [
          {
            "title": "max 80 chars",
            "body": "why this is a real defect and how to fix it",
            "confidence_score": 0.0,
            "priority": 0,
            "code_location": {
              "path": "relative/path",
              "line": 1
            }
          }
        ]
      }

      Priority scale: 0 is release blocking, 1 is high, 2 is medium, 3 is low.

      Pull request files from GitHub:
      #{file_summary.empty? ? "(no file metadata)" : file_summary}

      Pull request context:
      #{review_context.empty? ? "(no PR context)" : review_context}

      Changed files from git:
      #{changed_files_text.empty? ? "(no changed files)" : changed_files_text}

      Unified diff#{diff_truncated ? " (truncated)" : ""}:
      #{diff_text.empty? ? "(empty diff)" : diff_text}
    PROMPT
  end

  def extract_json(text)
    raw = text.to_s.strip
    return JSON.parse(raw) if raw.start_with?("{") && raw.end_with?("}")

    start = raw.index("{")
    finish = raw.rindex("}")
    raise "model response did not contain a JSON object" unless start && finish && finish > start

    JSON.parse(raw[start..finish])
  end

  def call_anthropic(prompt:, model:, api_key:)
    raise "ANTHROPIC_API_KEY is required for PR lens review" if api_key.to_s.empty?

    uri = URI("https://api.anthropic.com/v1/messages")
    request = Net::HTTP::Post.new(uri)
    request["anthropic-version"] = "2023-06-01"
    request["content-type"] = "application/json"
    request["x-api-key"] = api_key
    request.body = JSON.generate(
      model: model,
      max_tokens: 6000,
      system: "You are a careful EvalOps PR reviewer. Return valid JSON only.",
      messages: [
        {
          role: "user",
          content: prompt
        }
      ]
    )

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end
    unless response.is_a?(Net::HTTPSuccess)
      raise "Anthropic API failed with HTTP #{response.code}: #{response.body}"
    end

    body = JSON.parse(response.body)
    body.fetch("content").map { |part| part["text"] }.compact.join("\n")
  end

  def call_openai(prompt:, model:, api_key:)
    raise "OPENAI_API_KEY is required for OpenAI PR lens review" if api_key.to_s.empty?

    uri = URI("https://api.openai.com/v1/responses")
    request = Net::HTTP::Post.new(uri)
    request["authorization"] = "Bearer #{api_key}"
    request["content-type"] = "application/json"
    request.body = JSON.generate(
      model: model,
      input: [
        {
          role: "system",
          content: "You are a careful EvalOps PR reviewer. Return valid JSON only."
        },
        {
          role: "user",
          content: prompt
        }
      ]
    )

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end
    unless response.is_a?(Net::HTTPSuccess)
      raise "OpenAI API failed with HTTP #{response.code}: #{response.body}"
    end

    body = JSON.parse(response.body)
    return body["output_text"] if body["output_text"].to_s.strip.length.positive?

    Array(body["output"]).flat_map do |item|
      Array(item["content"]).map { |part| part["text"] }
    end.compact.join("\n")
  end

  def call_llm(prompt:, provider:, model:)
    case provider
    when "anthropic"
      call_anthropic(
        prompt: prompt,
        model: model,
        api_key: ENV["ANTHROPIC_API_KEY"] || ENV["EVALOPS_ANTHROPIC_API_KEY"]
      )
    when "openai"
      call_openai(
        prompt: prompt,
        model: model,
        api_key: ENV["OPENAI_API_KEY"] || ENV["EVALOPS_OPENAI_API_KEY"]
      )
    else
      raise "unsupported PR lens provider #{provider.inspect}; expected anthropic or openai"
    end
  end

  def coerce_number(value, default:, min:, max:)
    number = Float(value)
    [[number, min].max, max].min
  rescue ArgumentError, TypeError
    default
  end

  def normalize_finding(finding)
    location = finding.fetch("code_location", {})
    path = location["path"] || location["absolute_file_path"] || location["file"] || "unknown"
    line = location["line"] || location.dig("line_range", "start") || 1

    {
      "title" => finding.fetch("title").to_s.strip[0, 80],
      "body" => finding.fetch("body").to_s.strip,
      "confidence_score" => coerce_number(
        finding.fetch("confidence_score", 0.0),
        default: 0.0,
        min: 0.0,
        max: 1.0
      ),
      "priority" => Integer(finding.fetch("priority", 2)).clamp(0, 3),
      "code_location" => {
        "path" => path.to_s.sub(%r{\A\./}, ""),
        "line" => Integer(line)
      }
    }
  rescue ArgumentError, KeyError, TypeError
    nil
  end

  def normalize_lens_review(raw_review, repo:, pr:, lens:, head_sha:)
    findings = Array(raw_review["findings"]).map { |finding| normalize_finding(finding) }.compact
    top_confidence = findings.map { |finding| finding.fetch("confidence_score") }.max || 0.0
    confidence = coerce_number(
      raw_review.fetch("confidence_score", top_confidence),
      default: top_confidence,
      min: 0.0,
      max: 1.0
    )

    {
      "schema_version" => 1,
      "repo" => repo,
      "pr" => Integer(pr),
      "lens" => lens,
      "check_id" => check_context(lens),
      "head_sha" => head_sha,
      "generated_at" => Time.now.utc.iso8601,
      "summary" => raw_review.fetch("summary", "").to_s.strip,
      "confidence_score" => confidence,
      "findings" => findings
    }
  end

  def run_lens(repo:, pr:, lens:, workspace:, base_sha:, head_sha:, output:, provider:, model:, max_diff_bytes:)
    pr_json = pr_metadata(repo: repo, pr: pr)
    file_summary = pr_file_summary(repo: repo, pr: pr)
    review_context = pr_review_context(repo: repo, pr: pr, pr_json: pr_json, head_sha: head_sha)
    changed_files_text = changed_files(workspace: workspace, base_sha: base_sha, head_sha: head_sha)
    diff_text, diff_truncated = git_diff(
      workspace: workspace,
      base_sha: base_sha,
      head_sha: head_sha,
      max_bytes: max_diff_bytes
    )
    prompt = build_lens_prompt(
      repo: repo,
      pr: pr,
      lens: lens,
      pr_json: pr_json,
      file_summary: file_summary,
      review_context: review_context,
      changed_files_text: changed_files_text,
      diff_text: diff_text,
      diff_truncated: diff_truncated
    )
    raw_response = call_llm(
      prompt: prompt,
      provider: provider,
      model: model
    )
    normalized = normalize_lens_review(
      extract_json(raw_response),
      repo: repo,
      pr: pr,
      lens: lens,
      head_sha: head_sha
    )
    File.write(output, JSON.pretty_generate(normalized))
    normalized
  end

  def lens_status_description(review)
    if review.fetch("status", "") == "skipped"
      reason = review.fetch("skip_reason", "not applicable")
      return "Skipped: #{reason}"
    end

    findings = review.fetch("findings", [])
    confidence = findings.map { |finding| finding.fetch("confidence_score") }.max || 0.0
    "#{findings.length} finding#{findings.length == 1 ? "" : "s"}; top confidence #{format("%.2f", confidence)}"
  end

  def read_lens_reviews(root)
    Dir.glob(File.join(root, "**", "lens-review.json")).sort.map do |path|
      JSON.parse(File.read(path)).merge("_artifact_path" => path)
    end
  end

  def read_expected_reviews(root)
    Dir.glob(File.join(root, "**", "pr-lens-targets.json")).sort.flat_map do |path|
      JSON.parse(File.read(path)).flat_map do |pr|
        Array(pr.fetch("lenses", [])).map do |lens|
          {
            "repo" => pr.fetch("repo"),
            "pr" => Integer(pr.fetch("number")),
            "lens" => lens,
            "head_sha" => pr.fetch("head_sha"),
            "check_id" => check_context(lens),
            "_artifact_path" => path
          }
        end
      end
    end
  end

  def high_confidence_findings(reviews, min_confidence:)
    reviews.flat_map do |review|
      review.fetch("findings", []).map do |finding|
        finding.merge(
          "repo" => review.fetch("repo"),
          "pr" => review.fetch("pr"),
          "lens" => review.fetch("lens"),
          "head_sha" => review.fetch("head_sha"),
          "check_id" => review.fetch("check_id")
        )
      end
    end.select do |finding|
      finding.fetch("confidence_score") >= min_confidence
    end
  end

  def dedupe_and_rank(findings)
    best_by_key = {}
    findings.each do |finding|
      location = finding.fetch("code_location")
      key = [
        finding.fetch("repo"),
        finding.fetch("pr"),
        location.fetch("path"),
        location.fetch("line"),
        finding.fetch("title").downcase.gsub(/\s+/, " ")
      ]
      existing = best_by_key[key]
      if existing.nil? || finding.fetch("confidence_score") > existing.fetch("confidence_score")
        best_by_key[key] = finding
      end
    end

    best_by_key.values.sort_by do |finding|
      [
        -finding.fetch("confidence_score"),
        finding.fetch("priority"),
        finding.fetch("lens")
      ]
    end
  end

  def grouped_by_pr(findings)
    findings.group_by { |finding| [finding.fetch("repo"), finding.fetch("pr"), finding.fetch("head_sha")] }
  end

  def run_url
    return ENV["RUN_URL"] if ENV["RUN_URL"] && !ENV["RUN_URL"].empty?

    server = ENV.fetch("GITHUB_SERVER_URL", "https://github.com")
    repo = ENV["GITHUB_REPOSITORY"]
    run_id = ENV["GITHUB_RUN_ID"]
    return nil if repo.to_s.empty? || run_id.to_s.empty?

    "#{server}/#{repo}/actions/runs/#{run_id}"
  end

  def comment_body(repo:, pr:, findings:, min_confidence:, target_url:)
    lines = [
      MARKER,
      "**EvalOps PR lens review**",
      "",
      "High-confidence findings only. Threshold: #{format("%.2f", min_confidence)}.",
      "Run: #{target_url || "unavailable"}",
      ""
    ]

    findings.first(MAX_FINDINGS_PER_COMMENT).each_with_index do |finding, index|
      location = finding.fetch("code_location")
      lines << "#{index + 1}. **P#{finding.fetch("priority")} #{format("%.2f", finding.fetch("confidence_score"))} #{finding.fetch("lens")}**: #{finding.fetch("title")}"
      lines << "   - Location: `#{location.fetch("path")}:#{location.fetch("line")}`"
      lines << "   - Check: `#{finding.fetch("check_id")}`"
      lines << "   - #{finding.fetch("body")}"
      lines << ""
    end

    if findings.length > MAX_FINDINGS_PER_COMMENT
      lines << "_#{findings.length - MAX_FINDINGS_PER_COMMENT} additional high-confidence finding(s) were omitted from the comment; inspect the workflow artifact for the full ledger._"
      lines << ""
    end

    lines << "_Repo: #{repo} PR: ##{pr}_"
    lines.join("\n")
  end

  def marker_comment_ids(repo:, pr:)
    raw = gh_api(
      "--paginate",
      "repos/#{repo}/issues/#{pr}/comments",
      "--jq",
      ".[] | select(.body | contains(\"#{MARKER}\")) | .id"
    )
    raw.lines.map(&:strip).reject(&:empty?)
  end

  def upsert_comment(repo:, pr:, body:)
    ids = marker_comment_ids(repo: repo, pr: pr)
    if ids.empty?
      gh_api(
        "--method", "POST", "repos/#{repo}/issues/#{pr}/comments",
        input: JSON.generate({ body: body })
      )
    else
      first, *stale = ids
      gh_api(
        "--method", "PATCH", "repos/#{repo}/issues/comments/#{first}",
        input: JSON.generate({ body: body })
      )
      stale.each { |id| gh_api("--method", "DELETE", "repos/#{repo}/issues/comments/#{id}") }
    end
  end

  def delete_marker_comments(repo:, pr:)
    marker_comment_ids(repo: repo, pr: pr).each do |id|
      gh_api("--method", "DELETE", "repos/#{repo}/issues/comments/#{id}")
    end
  end

  def meta_state(findings, coverage_incomplete: false)
    return "error" if coverage_incomplete

    findings.any? { |finding| finding.fetch("priority") <= 1 } ? "failure" : "success"
  end

  def meta_description(findings, missing_count: 0, skipped_count: 0)
    if missing_count.positive?
      "PR lens coverage incomplete: #{missing_count} missing"
    elsif findings.empty? && skipped_count.positive?
      "No findings; #{skipped_count} lens review#{skipped_count == 1 ? "" : "s"} skipped"
    elsif findings.empty?
      "No high-confidence PR lens findings"
    else
      "#{findings.length} high-confidence finding#{findings.length == 1 ? "" : "s"}"
    end
  end

  def meta_review(artifact_root:, min_confidence:, output:)
    reviews = read_lens_reviews(artifact_root)
    expected_reviews = read_expected_reviews(artifact_root)
    reviews_by_key = reviews.each_with_object({}) do |review, hash|
      hash[[review.fetch("repo"), Integer(review.fetch("pr")), review.fetch("lens"), review.fetch("head_sha")]] = review
    end
    ranked = dedupe_and_rank(high_confidence_findings(reviews, min_confidence: min_confidence))
    grouped = grouped_by_pr(ranked)
    target_url = run_url
    coverage_by_pr = {}

    expected_reviews.group_by { |review| [review.fetch("repo"), review.fetch("pr"), review.fetch("head_sha")] }.each do |key, rows|
      coverage_by_pr[key] = {
        "expected" => rows.length,
        "missing" => rows.count do |row|
          !reviews_by_key.key?([row.fetch("repo"), row.fetch("pr"), row.fetch("lens"), row.fetch("head_sha")])
        end,
        "skipped" => rows.count do |row|
          review = reviews_by_key[[row.fetch("repo"), row.fetch("pr"), row.fetch("lens"), row.fetch("head_sha")]]
          review && review.fetch("status", "") == "skipped"
        end,
        "lenses" => rows.map { |row| row.fetch("lens") }.sort
      }
    end

    review_keys = reviews.group_by { |review| [review.fetch("repo"), review.fetch("pr"), review.fetch("head_sha")] }.keys
    (coverage_by_pr.keys + review_keys).uniq.each do |repo, pr, head_sha|
      findings = grouped.fetch([repo, pr, head_sha], [])
      coverage = coverage_by_pr.fetch(
        [repo, pr, head_sha],
        {
          "expected" => reviews.count { |review| review.fetch("repo") == repo && review.fetch("pr") == pr && review.fetch("head_sha") == head_sha },
          "missing" => 0,
          "skipped" => 0,
          "lenses" => reviews.select { |review| review.fetch("repo") == repo && review.fetch("pr") == pr && review.fetch("head_sha") == head_sha }.map { |review| review.fetch("lens") }.sort
        }
      )
      if findings.empty?
        delete_marker_comments(repo: repo, pr: pr)
      else
        upsert_comment(
          repo: repo,
          pr: pr,
          body: comment_body(repo: repo, pr: pr, findings: findings, min_confidence: min_confidence, target_url: target_url)
        )
      end
      post_status(
        repo: repo,
        sha: head_sha,
        context: meta_context,
        state: meta_state(findings, coverage_incomplete: coverage.fetch("missing").positive?),
        description: meta_description(
          findings,
          missing_count: coverage.fetch("missing"),
          skipped_count: coverage.fetch("skipped")
        ),
        target_url: target_url
      )
    end

    result = {
      "schema_version" => 1,
      "generated_at" => Time.now.utc.iso8601,
      "min_confidence" => min_confidence,
      "reviews" => reviews.length,
      "expected_reviews" => expected_reviews.length,
      "coverage" => coverage_by_pr.map do |(repo, pr, head_sha), coverage|
        coverage.merge("repo" => repo, "pr" => pr, "head_sha" => head_sha)
      end,
      "published_findings" => ranked,
      "run_url" => target_url
    }
    File.write(output, JSON.pretty_generate(result))
    result
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift

  case command
  when "discover"
    options = {
      repos: EvalOpsPrLensReview::TARGET_REPOS,
      lenses: EvalOpsPrLensReview::LENSES.keys
    }
    OptionParser.new do |parser|
      parser.on("--repos CSV") { |value| options[:repos] = EvalOpsPrLensReview.parse_list(value) }
      parser.on("--target-prs CSV") { |value| options[:target_prs] = value }
      parser.on("--github-output PATH") { |value| options[:github_output] = value }
      parser.on("--matrix-output PATH") { |value| options[:matrix_output] = value }
      parser.on("--targets-output PATH") { |value| options[:targets_output] = value }
    end.parse!

    pr_filter = EvalOpsPrLensReview.parse_pr_filter(options[:target_prs], repos: options[:repos]) if options[:target_prs]
    prs = EvalOpsPrLensReview.discover_open_prs(repos: options[:repos], pr_filter: pr_filter)
    matrix = EvalOpsPrLensReview.matrix_for(prs, lenses: options[:lenses])
    matrix_json = JSON.generate({ include: matrix })

    File.write(options[:matrix_output], JSON.pretty_generate({ include: matrix })) if options[:matrix_output]
    File.write(options[:targets_output], JSON.pretty_generate(prs)) if options[:targets_output]
    EvalOpsPrLensReview.write_github_outputs(
      options[:github_output],
      "matrix" => matrix_json,
      "has_work" => (!matrix.empty?).to_s,
      "pr_count" => prs.length.to_s
    )
    puts "Discovered #{prs.length} open PR(s), #{matrix.length} lens job(s)."
  when "post-status"
    options = {}
    OptionParser.new do |parser|
      parser.on("--repo OWNER/REPO") { |value| options[:repo] = value }
      parser.on("--sha SHA") { |value| options[:sha] = value }
      parser.on("--context CONTEXT") { |value| options[:context] = value }
      parser.on("--state STATE") { |value| options[:state] = value }
      parser.on("--description TEXT") { |value| options[:description] = value }
      parser.on("--target-url URL") { |value| options[:target_url] = value }
    end.parse!
    EvalOpsPrLensReview.post_status(**options)
  when "prepare-workspace"
    options = {
      token: ENV["REVIEW_TOKEN"] || ENV["GH_TOKEN"],
      github_output: ENV["GITHUB_OUTPUT"],
      snapshot_head_sha: "",
      snapshot_base_sha: ""
    }
    OptionParser.new do |parser|
      parser.on("--repo OWNER/REPO") { |value| options[:repo] = value }
      parser.on("--pr NUMBER", Integer) { |value| options[:pr] = value }
      parser.on("--lens LENS") { |value| options[:lens] = value }
      parser.on("--workspace PATH") { |value| options[:workspace] = value }
      parser.on("--output PATH") { |value| options[:output] = value }
      parser.on("--github-output PATH") { |value| options[:github_output] = value }
      parser.on("--snapshot-head-sha SHA") { |value| options[:snapshot_head_sha] = value }
      parser.on("--snapshot-base-sha SHA") { |value| options[:snapshot_base_sha] = value }
      parser.on("--token TOKEN") { |value| options[:token] = value }
    end.parse!
    required = %i[repo pr lens workspace output]
    missing = required.select { |key| options[key].nil? || options[key].to_s.empty? }
    raise OptionParser::MissingArgument, missing.join(", ") unless missing.empty?

    result = EvalOpsPrLensReview.prepare_workspace(**options)
    puts(result.fetch("skip") ? "Skipped #{options.fetch(:lens)}: #{result.fetch("reason")}" : "Prepared #{options.fetch(:repo)}##{options.fetch(:pr)}")
  when "run-lens"
    options = {
      provider: ENV.fetch("PR_LENS_PROVIDER", "anthropic"),
      model: ENV.fetch("PR_LENS_MODEL", EvalOpsPrLensReview::DEFAULT_MODEL),
      max_diff_bytes: Integer(ENV.fetch("PR_LENS_MAX_DIFF_BYTES", EvalOpsPrLensReview::DEFAULT_MAX_DIFF_BYTES))
    }
    OptionParser.new do |parser|
      parser.on("--repo OWNER/REPO") { |value| options[:repo] = value }
      parser.on("--pr NUMBER", Integer) { |value| options[:pr] = value }
      parser.on("--lens LENS") { |value| options[:lens] = value }
      parser.on("--workspace PATH") { |value| options[:workspace] = value }
      parser.on("--base-sha SHA") { |value| options[:base_sha] = value }
      parser.on("--head-sha SHA") { |value| options[:head_sha] = value }
      parser.on("--output PATH") { |value| options[:output] = value }
      parser.on("--provider PROVIDER") { |value| options[:provider] = value }
      parser.on("--model MODEL") { |value| options[:model] = value }
      parser.on("--max-diff-bytes BYTES", Integer) { |value| options[:max_diff_bytes] = value }
    end.parse!
    required = %i[repo pr lens workspace base_sha head_sha output]
    missing = required.select { |key| options[key].nil? || options[key].to_s.empty? }
    raise OptionParser::MissingArgument, missing.join(", ") unless missing.empty?

    review = EvalOpsPrLensReview.run_lens(**options)
    puts EvalOpsPrLensReview.lens_status_description(review)
  when "lens-status-description"
    options = {}
    OptionParser.new do |parser|
      parser.on("--review-json PATH") { |value| options[:review_json] = value }
    end.parse!
    review = JSON.parse(File.read(options.fetch(:review_json)))
    puts EvalOpsPrLensReview.lens_status_description(review)
  when "meta-review"
    options = {
      min_confidence: Float(ENV.fetch("PR_LENS_MIN_CONFIDENCE", EvalOpsPrLensReview::DEFAULT_MIN_CONFIDENCE)),
      output: "meta-review.json"
    }
    OptionParser.new do |parser|
      parser.on("--artifact-root PATH") { |value| options[:artifact_root] = value }
      parser.on("--min-confidence NUMBER", Float) { |value| options[:min_confidence] = value }
      parser.on("--output PATH") { |value| options[:output] = value }
    end.parse!
    raise OptionParser::MissingArgument, "artifact-root" if options[:artifact_root].to_s.empty?

    result = EvalOpsPrLensReview.meta_review(**options)
    puts "Published #{result.fetch("published_findings").length} high-confidence finding(s)."
  when "dispatch-review-requests"
    options = {
      owner: "evalops",
      reviewer: "EvalOpsBot",
      limit: 100,
      dry_run: false,
      target_url: EvalOpsPrLensReview.run_url
    }
    OptionParser.new do |parser|
      parser.on("--owner OWNER") { |value| options[:owner] = value }
      parser.on("--reviewer LOGIN") { |value| options[:reviewer] = value }
      parser.on("--limit NUMBER", Integer) { |value| options[:limit] = value }
      parser.on("--dry-run") { options[:dry_run] = true }
      parser.on("--target-url URL") { |value| options[:target_url] = value }
      parser.on("--output PATH") { |value| options[:output] = value }
      parser.on("--github-output PATH") { |value| options[:github_output] = value }
    end.parse!

    result = EvalOpsPrLensReview.dispatch_requested_reviews(**options.slice(:owner, :reviewer, :limit, :dry_run, :target_url, :output))
    EvalOpsPrLensReview.write_github_outputs(
      options[:github_output],
      "candidate_count" => result.fetch("candidate_count"),
      "dispatched_count" => result.fetch("dispatched_count"),
      "skipped_count" => result.fetch("skipped_count")
    )
    puts "Found #{result.fetch("candidate_count")} EvalOpsBot review request(s); dispatched #{result.fetch("dispatched_count")}, skipped #{result.fetch("skipped_count")}."
  else
    warn "usage: #{$PROGRAM_NAME} discover|post-status|prepare-workspace|run-lens|lens-status-description|meta-review|dispatch-review-requests"
    exit 2
  end
end
