#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "open3"
require "tempfile"

module CodexStructuredReview
  MARKER = "<!-- evalops-codex-structured-review -->"

  module_function

  def normalize_path(path, workspace: ENV.fetch("GITHUB_WORKSPACE", Dir.pwd))
    raw = path.to_s.strip
    root = File.expand_path(workspace.to_s)
    expanded = File.expand_path(raw)

    if expanded.start_with?("#{root}/")
      expanded.delete_prefix("#{root}/")
    else
      raw.sub(%r{\A\./}, "")
    end
  end

  def finding_payload(finding, commit:)
    location = finding.fetch("code_location")
    line_range = location.fetch("line_range")
    start_line = Integer(line_range.fetch("start"))
    end_line = Integer(line_range.fetch("end"))
    start_line, end_line = [end_line, start_line] if start_line > end_line

    body = +"#{finding.fetch("title")}\n\n#{finding.fetch("body")}"
    body << "\n\nPriority: P#{finding.fetch("priority")}"
    body << "\nConfidence: #{finding.fetch("confidence_score")}"

    payload = {
      body: body,
      commit_id: commit,
      path: normalize_path(location.fetch("absolute_file_path")),
      line: end_line,
      side: "RIGHT"
    }
    if start_line != end_line
      payload[:start_line] = start_line
      payload[:start_side] = "RIGHT"
    end
    payload
  end

  def summary_body(review)
    findings = review.fetch("findings", [])
    [
      MARKER,
      "**Codex structured review**",
      "",
      "Verdict: #{review.fetch("overall_correctness")}",
      "Confidence: #{review.fetch("overall_confidence_score")}",
      "Findings: #{findings.length}",
      "",
      review.fetch("overall_explanation")
    ].join("\n")
  end

  def gh_api(*args, input: nil)
    command = ["gh", "api", *args]
    if input
      Tempfile.create(["codex-review", ".json"]) do |file|
        file.write(input)
        file.flush
        command += ["--input", file.path]
        stdout, stderr, status = Open3.capture3(*command)
        return [stdout, stderr, status]
      end
    end

    Open3.capture3(*command)
  end

  def post_line_comment(repo:, pr:, payload:, dry_run: false)
    return ["DRY_RUN #{JSON.generate(payload)}", "", true] if dry_run

    stdout, stderr, status = gh_api(
      "--method",
      "POST",
      "repos/#{repo}/pulls/#{pr}/comments",
      input: JSON.generate(payload)
    )
    [stdout, stderr, status.success?]
  end

  def upsert_summary(repo:, pr:, body:, dry_run: false)
    return ["DRY_RUN #{body}", "", true] if dry_run

    stdout, stderr, status = gh_api(
      "--paginate",
      "repos/#{repo}/issues/#{pr}/comments",
      "--jq",
      ".[] | select(.body | contains(\"#{MARKER}\")) | .id"
    )
    return [stdout, stderr, false] unless status.success?

    existing_id = stdout.lines.first&.strip
    if existing_id && !existing_id.empty?
      gh_api(
        "--method",
        "PATCH",
        "repos/#{repo}/issues/comments/#{existing_id}",
        input: JSON.generate({ body: body })
      ).then { |out, err, patch_status| [out, err, patch_status.success?] }
    else
      gh_api(
        "--method",
        "POST",
        "repos/#{repo}/issues/#{pr}/comments",
        input: JSON.generate({ body: body })
      ).then { |out, err, create_status| [out, err, create_status.success?] }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    dry_run: false
  }

  OptionParser.new do |parser|
    parser.on("--review-json PATH", "Codex structured review JSON") { |value| options[:review_json] = value }
    parser.on("--repo OWNER/REPO", "GitHub repository") { |value| options[:repo] = value }
    parser.on("--pr NUMBER", Integer, "Pull request number") { |value| options[:pr] = value }
    parser.on("--commit SHA", "Head commit SHA") { |value| options[:commit] = value }
    parser.on("--dry-run", "Print payloads without calling GitHub") { options[:dry_run] = true }
  end.parse!

  missing = %i[review_json repo pr commit].select { |key| options[key].nil? || options[key].to_s.empty? }
  unless missing.empty?
    warn "missing required options: #{missing.join(", ")}"
    exit 2
  end

  review = JSON.parse(File.read(options.fetch(:review_json)))
  failures = []

  review.fetch("findings", []).each do |finding|
    payload = CodexStructuredReview.finding_payload(finding, commit: options.fetch(:commit))
    stdout, stderr, ok = CodexStructuredReview.post_line_comment(
      repo: options.fetch(:repo),
      pr: options.fetch(:pr),
      payload: payload,
      dry_run: options.fetch(:dry_run)
    )
    puts stdout unless stdout.empty?
    next if ok

    failures << "#{payload[:path]}:#{payload[:line]} #{stderr.strip}"
    warn "failed to post Codex finding for #{payload[:path]}:#{payload[:line]}: #{stderr.strip}"
  end

  stdout, stderr, ok = CodexStructuredReview.upsert_summary(
    repo: options.fetch(:repo),
    pr: options.fetch(:pr),
    body: CodexStructuredReview.summary_body(review),
    dry_run: options.fetch(:dry_run)
  )
  puts stdout unless stdout.empty?
  unless ok
    warn "failed to upsert Codex summary: #{stderr.strip}"
    failures << "summary #{stderr.strip}"
  end

  if failures.empty?
    puts "Published Codex structured review."
  else
    warn "Codex structured review completed with #{failures.length} publishing failure(s)."
    exit 1
  end
end
