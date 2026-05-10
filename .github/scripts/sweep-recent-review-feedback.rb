#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "open3"
require "optparse"
require "tempfile"
require "time"
require_relative "check-pr-review-threads"

module EvalOpsReviewFeedbackSweep
  module_function

  DEFAULT_TITLE = "[codex] Recent unresolved review feedback"
  LEDGER_SCHEMA_VERSION = "evalops.review_feedback_ledger.v1"
  GUARDRAIL_BACKLOG_SCHEMA_VERSION = "evalops.review_feedback_guardrail_backlog.v1"

  GUARDRAIL_CLASSES = [
    {
      "key" => "workflow-shell-footgun",
      "title" => "Workflow shell footgun",
      "patterns" => [/\.github\/workflows/, /\bactionlint\b/, /\bshell\b/, /\bbash\b/, /\bset -e\b/, /\bworkflow\b/],
      "recommended_guardrail" => "Add or extend workflow lint/security checks so fragile shell and GitHub Actions mistakes fail before review."
    },
    {
      "key" => "generated-contract-drift",
      "title" => "Generated contract drift",
      "patterns" => [/\bproto\b/, /\bprotobuf\b/, /\bbuf\b/, /\bgenerated\b/, %r{\bgen/}, /\bsdk\b/, /\bopenapi\b/, /\bjsonschema\b/],
      "recommended_guardrail" => "Add generated-output drift checks and fixture coverage around the touched API or schema surface."
    },
    {
      "key" => "release-train-drift",
      "title" => "Release train drift",
      "patterns" => [/\brelease\b/, /\bversion\b/, /\bpublish\b/, /\bpackage\b/, /\bchangelog\b/, /\bcutover\b/, /\bregistry\b/],
      "recommended_guardrail" => "Add release metadata and changelog coverage checks tied to the package or deploy artifact that changed."
    },
    {
      "key" => "runtime-smoke-coverage",
      "title" => "Runtime smoke coverage gap",
      "patterns" => [/\bsmoke\b/, /\bruntime\b/, /\bagentruntime\b/, /\breplay\b/, /\breceipt\b/, /\boutbox\b/, /\breadiness\b/, /\bhealth\b/, /\bstaging\b/, /\bmetadata\b/, /\bcorrelation\b/, /\bevidence\b/],
      "recommended_guardrail" => "Add a smoke or preflight fixture that proves the runtime-visible behavior and required evidence fields."
    },
    {
      "key" => "configuration-safety",
      "title" => "Configuration safety",
      "patterns" => [/\bkustomize\b/, /\bkubernetes\b/, /\bk8s\b/, /\bterraform\b/, /\bselector\b/, /\bnamespace\b/, /\bdesired-state\b/, /\byaml\b/],
      "recommended_guardrail" => "Add desired-state validation that renders and checks configuration invariants before apply or merge."
    },
    {
      "key" => "security-authz",
      "title" => "Security or authorization gap",
      "patterns" => [/\bauth\b/, /\bauthoriz/, /\bpermission\b/, /\btoken\b/, /\bcredential\b/, /\bsecret\b/, /\bcsrf\b/, /\binjection\b/, /\bsecurity\b/],
      "recommended_guardrail" => "Add an auth/security regression test or static rule covering the vulnerable boundary."
    },
    {
      "key" => "test-coverage-gap",
      "title" => "Test coverage gap",
      "patterns" => [/\btest\b/, /\bcoverage\b/, /\bfixture\b/, /\bassert\b/, /\bfuzz\b/, /\bregression\b/, /\bmissing case\b/],
      "recommended_guardrail" => "Add focused regression or fuzz coverage for the exact missed case, then wire it into the smallest relevant CI target."
    },
    {
      "key" => "docs-runbook-drift",
      "title" => "Docs or runbook drift",
      "patterns" => [/\breadme\b/, /\bdocs?\b/, /\brunbook\b/, /\bguide\b/, /\bcomment\b/, /\bdescription\b/],
      "recommended_guardrail" => "Add docs/runbook coverage or metadata checks only when the documented operator path changed."
    }
  ].freeze

  SEVERITY_SCORE = {
    "p0" => 100,
    "p1" => 80,
    "high" => 50,
    "medium" => 20,
    "low" => 5,
    "none" => 0
  }.freeze

  def gh(*args, input: nil)
    command = ["gh", *args]
    if input
      Tempfile.create(["review-feedback-sweep", ".md"]) do |file|
        file.write(input)
        file.flush
        stdout, stderr, status = Open3.capture3(*command, "--body-file", file.path)
        return [stdout, stderr, status]
      end
    end

    Open3.capture3(*command)
  end

  def search_recent_prs(owner:, since:, limit: 100)
    stdout, stderr, status = gh(
      "search",
      "prs",
      "--owner",
      owner,
      "--merged",
      "--merged-at",
      ">=#{since}",
      "--limit",
      limit.to_s,
      "--json",
      "repository,number,url,title,closedAt"
    )
    raise "gh search prs failed: #{stderr.strip}" unless status.success?

    JSON.parse(stdout)
  end

  def feedback_items(owner:, since:, min_severity:, pr_limit: 100)
    search_recent_prs(owner: owner, since: since, limit: pr_limit).flat_map do |pr|
      repo = pr.fetch("repository").fetch("nameWithOwner")
      payload = EvalOpsReviewThreadGuard.fetch_payload(repo: repo, pr: pr.fetch("number"))
      EvalOpsReviewThreadGuard.blocking_feedback(payload, min_severity: min_severity).map do |item|
        item.merge(
          repo: repo,
          pr_number: pr.fetch("number"),
          pr_title: pr.fetch("title"),
          pr_url: pr.fetch("url"),
          merged_at: pr["closedAt"]
        )
      end
    end
  end

  def report_markdown(items, owner:, since:, min_severity:)
    lines = [
      "# Recent unresolved review feedback",
      "",
      "- Owner: `#{owner}`",
      "- Merged since: `#{since}`",
      "- Minimum severity: `#{min_severity}`",
      "- Findings: `#{items.length}`",
      "",
      "<!-- evalops-review-feedback-sweep -->"
    ]
    if items.empty?
      lines << ""
      lines << "No unresolved review feedback found."
      return lines.join("\n")
    end

    lines << ""
    items.each do |item|
      location = item[:path] ? "#{item[:path]}:#{item[:line] || "?"}" : item.fetch(:kind).to_s
      lines << "- `#{item.fetch(:severity)}` #{item.fetch(:repo)}##{item.fetch(:pr_number)} #{location}"
      lines << "  - PR: #{item.fetch(:pr_url)}"
      lines << "  - Feedback: #{item[:url]}"
      first_line = body_first_line(item.fetch(:body))
      lines << "  - #{first_line}" unless first_line.empty?
    end
    lines.join("\n")
  end

  def feedback_class(item)
    case item.fetch(:kind)
    when "review_thread"
      "review_thread"
    when "pr_comment"
      "top_level_pr_comment"
    when "pr_review"
      "top_level_pr_review"
    else
      "unknown"
    end
  end

  def body_first_line(body)
    line = body.to_s.lines.map(&:strip).find do |candidate|
      next false if candidate.empty?
      next false if candidate.match?(/\A###\s+.*Codex Review\b/i)
      next false if candidate.match?(%r{\Ahttps://github\.com/}i)
      next false if candidate.match?(/\A<details>/i)

      true
    end.to_s
    return line unless line.match?(/<sub|!\[/)

    line
      .gsub(/!\[[^\]]*\]\([^)]*\)/, "")
      .gsub(%r{</?[^>]+>}, "")
      .gsub("**", "")
      .squeeze(" ")
      .strip
  end

  def ledger_entry(item)
    body = item.fetch(:body).to_s
    {
      "repo" => item.fetch(:repo),
      "pr_number" => item.fetch(:pr_number),
      "pr_title" => item.fetch(:pr_title),
      "pr_url" => item.fetch(:pr_url),
      "merged_at" => item["merged_at"] || item[:merged_at],
      "kind" => item.fetch(:kind),
      "feedback_class" => feedback_class(item),
      "severity" => item.fetch(:severity),
      "feedback_url" => item[:url],
      "path" => item[:path],
      "line" => item[:line],
      "author" => item[:author],
      "state" => item[:state],
      "is_outdated" => item[:is_outdated],
      "body_first_line" => body_first_line(body),
      "body_sha256" => Digest::SHA256.hexdigest(body)
    }.compact
  end

  def ledger_json(items, owner:, since:, min_severity:, generated_at: Time.now.utc)
    {
      "schema_version" => LEDGER_SCHEMA_VERSION,
      "generated_at" => generated_at.utc.iso8601,
      "owner" => owner,
      "merged_since" => since,
      "min_severity" => min_severity,
      "finding_count" => items.length,
      "findings" => items.map { |item| ledger_entry(item) }
    }
  end

  def guardrail_class(finding)
    haystack = [
      finding["repo"],
      finding["pr_title"],
      finding["path"],
      finding["body_first_line"],
      finding["feedback_class"],
      finding["kind"]
    ].compact.join("\n").downcase

    GUARDRAIL_CLASSES.find do |candidate|
      candidate.fetch("patterns").any? { |pattern| haystack.match?(pattern) }
    end || {
      "key" => "other-feedback",
      "title" => "Other feedback",
      "recommended_guardrail" => "Review manually before converting this class into a repo-local guardrail."
    }
  end

  def severity_score(severity)
    SEVERITY_SCORE.fetch(severity.to_s.downcase, 0)
  end

  def guardrail_backlog_json(ledger, generated_at: Time.now.utc, sample_limit: 3)
    findings = Array(ledger.fetch("findings"))
    grouped = findings.group_by { |finding| guardrail_class(finding).fetch("key") }
    classes = grouped.map do |key, class_findings|
      metadata = guardrail_class(class_findings.first)
      repos = class_findings.map { |finding| finding.fetch("repo") }.uniq.sort
      score = class_findings.sum { |finding| severity_score(finding["severity"]) } + ((repos.length - 1) * 10)
      {
        "key" => key,
        "title" => metadata.fetch("title"),
        "score" => score,
        "finding_count" => class_findings.length,
        "repo_count" => repos.length,
        "repos" => repos,
        "recommended_guardrail" => metadata.fetch("recommended_guardrail"),
        "sample_findings" => class_findings.first(sample_limit).map do |finding|
          finding.slice(
            "repo",
            "pr_number",
            "pr_title",
            "feedback_url",
            "path",
            "line",
            "severity",
            "body_first_line"
          )
        end
      }
    end.sort_by { |entry| [-entry.fetch("score"), -entry.fetch("finding_count"), entry.fetch("key")] }

    {
      "schema_version" => GUARDRAIL_BACKLOG_SCHEMA_VERSION,
      "source_schema_version" => ledger.fetch("schema_version"),
      "generated_at" => generated_at.utc.iso8601,
      "owner" => ledger.fetch("owner"),
      "merged_since" => ledger.fetch("merged_since"),
      "min_severity" => ledger.fetch("min_severity"),
      "source_finding_count" => findings.length,
      "class_count" => classes.length,
      "classes" => classes
    }
  end

  def guardrail_backlog_markdown(backlog)
    lines = [
      "# Review feedback guardrail backlog",
      "",
      "- Owner: `#{backlog.fetch("owner")}`",
      "- Merged since: `#{backlog.fetch("merged_since")}`",
      "- Minimum severity: `#{backlog.fetch("min_severity")}`",
      "- Source findings: `#{backlog.fetch("source_finding_count")}`",
      "- Classes: `#{backlog.fetch("class_count")}`",
      "",
      "<!-- evalops-review-feedback-guardrail-backlog -->"
    ]

    if backlog.fetch("classes").empty?
      lines << ""
      lines << "No guardrail candidates found."
      return lines.join("\n")
    end

    lines << ""
    lines << "| Rank | Class | Score | Findings | Repos | Recommended guardrail |"
    lines << "| --- | --- | ---: | ---: | --- | --- |"
    backlog.fetch("classes").each_with_index do |entry, index|
      lines << "| #{index + 1} | `#{entry.fetch("key")}` #{entry.fetch("title")} | #{entry.fetch("score")} | #{entry.fetch("finding_count")} | #{entry.fetch("repos").join(", ")} | #{entry.fetch("recommended_guardrail")} |"
    end

    backlog.fetch("classes").each do |entry|
      lines << ""
      lines << "## #{entry.fetch("title")}"
      entry.fetch("sample_findings").each do |finding|
        location = finding["path"] ? "#{finding["path"]}:#{finding["line"] || "?"}" : "top-level feedback"
        lines << "- `#{finding.fetch("severity")}` #{finding.fetch("repo")}##{finding.fetch("pr_number")} #{location}"
        lines << "  - #{finding.fetch("body_first_line")}" unless finding.fetch("body_first_line", "").empty?
        lines << "  - #{finding.fetch("feedback_url")}" if finding["feedback_url"]
      end
    end

    lines.join("\n")
  end

  def upsert_issue(repo:, title:, body:)
    stdout, stderr, status = gh(
      "issue",
      "list",
      "--repo",
      repo,
      "--state",
      "open",
      "--search",
      "\"#{title}\" in:title",
      "--limit",
      "1",
      "--json",
      "number"
    )
    raise "gh issue list failed: #{stderr.strip}" unless status.success?

    number = JSON.parse(stdout).first&.fetch("number", nil)
    if number
      gh("issue", "comment", number.to_s, "--repo", repo, input: body).then do |_out, err, ok|
        raise "gh issue comment failed: #{err.strip}" unless ok.success?
      end
      number
    else
      gh("issue", "create", "--repo", repo, "--title", title, input: body).then do |out, err, ok|
        raise "gh issue create failed: #{err.strip}" unless ok.success?

        out.strip
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    owner: "evalops",
    since_hours: 72,
    min_severity: "high",
    issue_repo: nil,
    issue_title: EvalOpsReviewFeedbackSweep::DEFAULT_TITLE,
    json_output: nil,
    guardrail_backlog_output: nil,
    guardrail_backlog_json_output: nil,
    pr_limit: 100,
    dry_run: false
  }

  OptionParser.new do |parser|
    parser.on("--owner OWNER", "GitHub owner/org to sweep") { |value| options[:owner] = value }
    parser.on("--since-hours HOURS", Integer, "Merged PR lookback window") { |value| options[:since_hours] = value }
    parser.on("--pr-limit LIMIT", Integer, "Maximum merged PRs to inspect") { |value| options[:pr_limit] = value }
    parser.on("--min-severity LEVEL", "Minimum severity to report") { |value| options[:min_severity] = value.downcase }
    parser.on("--issue-repo OWNER/REPO", "Create or comment on this issue repo when findings exist") { |value| options[:issue_repo] = value }
    parser.on("--issue-title TITLE", "Issue title for sweep findings") { |value| options[:issue_title] = value }
    parser.on("--json-output PATH", "Write machine-readable feedback ledger JSON to this path") { |value| options[:json_output] = value }
    parser.on("--guardrail-backlog-output PATH", "Write ranked guardrail backlog markdown to this path") { |value| options[:guardrail_backlog_output] = value }
    parser.on("--guardrail-backlog-json-output PATH", "Write ranked guardrail backlog JSON to this path") { |value| options[:guardrail_backlog_json_output] = value }
    parser.on("--dry-run", "Print report and skip issue writes") { options[:dry_run] = true }
  end.parse!

  unless EvalOpsReviewThreadGuard::SEVERITY_RANK.key?(options.fetch(:min_severity))
    warn "invalid --min-severity #{options.fetch(:min_severity).inspect}"
    exit 2
  end

  since = (Time.now.utc - (options.fetch(:since_hours) * 3600)).strftime("%Y-%m-%d")
  items = EvalOpsReviewFeedbackSweep.feedback_items(
    owner: options.fetch(:owner),
    since: since,
    min_severity: options.fetch(:min_severity),
    pr_limit: options.fetch(:pr_limit)
  )
  ledger = EvalOpsReviewFeedbackSweep.ledger_json(
    items,
    owner: options.fetch(:owner),
    since: since,
    min_severity: options.fetch(:min_severity)
  )
  body = EvalOpsReviewFeedbackSweep.report_markdown(
    items,
    owner: options.fetch(:owner),
    since: since,
    min_severity: options.fetch(:min_severity)
  )
  puts body

  if options[:json_output]
    File.write(options.fetch(:json_output), "#{JSON.pretty_generate(ledger)}\n")
  end

  if options[:guardrail_backlog_output] || options[:guardrail_backlog_json_output]
    backlog = EvalOpsReviewFeedbackSweep.guardrail_backlog_json(ledger)
    File.write(options.fetch(:guardrail_backlog_json_output), "#{JSON.pretty_generate(backlog)}\n") if options[:guardrail_backlog_json_output]
    File.write(options.fetch(:guardrail_backlog_output), "#{EvalOpsReviewFeedbackSweep.guardrail_backlog_markdown(backlog)}\n") if options[:guardrail_backlog_output]
  end

  if items.any? && options[:issue_repo] && !options.fetch(:dry_run)
    EvalOpsReviewFeedbackSweep.upsert_issue(
      repo: options.fetch(:issue_repo),
      title: options.fetch(:issue_title),
      body: body
    )
  end

  exit(items.empty? ? 0 : 1)
end
