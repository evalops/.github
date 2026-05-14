#!/usr/bin/env ruby
# frozen_string_literal: true

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
        "database migrations, schema ownership manifests, and generated migration embeds",
        "backward/forward compatibility during rolling deploys and rollback",
        "concurrent migration hazards, idempotency, and destructive DDL",
        "missing migration tests, dry-runs, or release-order constraints"
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

  MARKER = "<!-- evalops-pr-lens-review -->"
  DEFAULT_MIN_CONFIDENCE = 0.82
  DEFAULT_MODEL = "claude-opus-4-7"
  DEFAULT_MAX_DIFF_BYTES = 180_000
  MAX_FINDINGS_PER_COMMENT = 12

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

  def gh_api(*args, input: nil, token: ENV["GH_TOKEN"])
    env = {}
    env["GH_TOKEN"] = token if token && !token.empty?
    command = ["gh", "api", *args]

    if input
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

  def discover_open_prs(repos:, pr_filter: nil)
    repos.flat_map do |repo|
      normalized_repo = normalize_repo(repo)
      prs = gh_api_json("repos/#{normalized_repo}/pulls?state=open&per_page=100")
      prs.select! { |pr| pr_filter.fetch(normalized_repo, []).include?(Integer(pr.fetch("number"))) } if pr_filter
      prs.map do |pr|
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
          "head_ref" => pr.fetch("head").fetch("ref")
        }
      end
    end
  end

  def matrix_for(prs, lenses: LENSES.keys)
    prs.flat_map do |pr|
      lenses.map do |lens|
        valid_lens!(lens)
        {
          "repo" => pr.fetch("repo"),
          "repo_slug" => pr.fetch("repo_slug"),
          "pr" => pr.fetch("number"),
          "lens" => lens,
          "check_context" => check_context(lens),
          "head_sha" => pr.fetch("head_sha")
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

  def git_capture(workspace, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", workspace, *args)
    raise "git #{args.join(" ")} failed: #{stderr}" unless status.success?

    stdout
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

  def build_lens_prompt(repo:, pr:, lens:, pr_json:, file_summary:, changed_files_text:, diff_text:, diff_truncated:)
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
      temperature: 0,
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
    findings = review.fetch("findings", [])
    confidence = findings.map { |finding| finding.fetch("confidence_score") }.max || 0.0
    "#{findings.length} finding#{findings.length == 1 ? "" : "s"}; top confidence #{format("%.2f", confidence)}"
  end

  def read_lens_reviews(root)
    Dir.glob(File.join(root, "**", "lens-review.json")).sort.map do |path|
      JSON.parse(File.read(path)).merge("_artifact_path" => path)
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

  def meta_state(findings)
    findings.any? { |finding| finding.fetch("priority") <= 1 } ? "failure" : "success"
  end

  def meta_description(findings)
    if findings.empty?
      "No high-confidence PR lens findings"
    else
      "#{findings.length} high-confidence finding#{findings.length == 1 ? "" : "s"}"
    end
  end

  def meta_review(artifact_root:, min_confidence:, output:)
    reviews = read_lens_reviews(artifact_root)
    ranked = dedupe_and_rank(high_confidence_findings(reviews, min_confidence: min_confidence))
    grouped = grouped_by_pr(ranked)
    target_url = run_url

    reviews.group_by { |review| [review.fetch("repo"), review.fetch("pr"), review.fetch("head_sha")] }.each_key do |repo, pr, head_sha|
      findings = grouped.fetch([repo, pr, head_sha], [])
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
        state: meta_state(findings),
        description: meta_description(findings),
        target_url: target_url
      )
    end

    result = {
      "schema_version" => 1,
      "generated_at" => Time.now.utc.iso8601,
      "min_confidence" => min_confidence,
      "reviews" => reviews.length,
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
  else
    warn "usage: #{$PROGRAM_NAME} discover|post-status|run-lens|lens-status-description|meta-review"
    exit 2
  end
end
