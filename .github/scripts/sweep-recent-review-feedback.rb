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

  def search_recent_prs(owner:, since:)
    stdout, stderr, status = gh(
      "search",
      "prs",
      "--owner",
      owner,
      "--merged",
      "--merged-at",
      ">=#{since}",
      "--limit",
      "100",
      "--json",
      "repository,number,url,title,closedAt"
    )
    raise "gh search prs failed: #{stderr.strip}" unless status.success?

    JSON.parse(stdout)
  end

  def feedback_items(owner:, since:, min_severity:)
    search_recent_prs(owner: owner, since: since).flat_map do |pr|
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
      first_line = item.fetch(:body).lines.first.to_s.strip
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
      "body_first_line" => body.lines.first.to_s.strip,
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
    dry_run: false
  }

  OptionParser.new do |parser|
    parser.on("--owner OWNER", "GitHub owner/org to sweep") { |value| options[:owner] = value }
    parser.on("--since-hours HOURS", Integer, "Merged PR lookback window") { |value| options[:since_hours] = value }
    parser.on("--min-severity LEVEL", "Minimum severity to report") { |value| options[:min_severity] = value.downcase }
    parser.on("--issue-repo OWNER/REPO", "Create or comment on this issue repo when findings exist") { |value| options[:issue_repo] = value }
    parser.on("--issue-title TITLE", "Issue title for sweep findings") { |value| options[:issue_title] = value }
    parser.on("--json-output PATH", "Write machine-readable feedback ledger JSON to this path") { |value| options[:json_output] = value }
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
    ledger = EvalOpsReviewFeedbackSweep.ledger_json(
      items,
      owner: options.fetch(:owner),
      since: since,
      min_severity: options.fetch(:min_severity)
    )
    File.write(options.fetch(:json_output), "#{JSON.pretty_generate(ledger)}\n")
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
