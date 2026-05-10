#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "open3"
require "optparse"
require "set"
require "tempfile"
require "time"
require_relative "check-pr-review-threads"

module EvalOpsReviewFeedbackSweep
  module_function

  DEFAULT_TITLE = "[codex] Recent unresolved review feedback"
  DEFAULT_WEEKLY_REPORT_TITLE = "[codex] Weekly review feedback guardrail report"
  GUARDRAIL_ISSUE_TITLE_PREFIX = "[codex] Guardrail backlog:"
  REPO_GUARDRAIL_ISSUE_TITLE_PREFIX = "[codex] Guardrail candidate:"
  LEDGER_SCHEMA_VERSION = "evalops.review_feedback_ledger.v1"
  GUARDRAIL_BACKLOG_SCHEMA_VERSION = "evalops.review_feedback_guardrail_backlog.v1"
  GUARDRAIL_LIFECYCLE_SCHEMA_VERSION = "evalops.review_feedback_guardrail_lifecycle.v1"

  GUARDRAIL_CLASSES = [
    {
      "key" => "workflow-shell-footgun",
      "title" => "Workflow shell footgun",
      "patterns" => [/\.github\/workflows/, /\bactionlint\b/, /\bshell\b/, /\bbash\b/, /\bset -e\b/, /\bworkflow\b/],
      "recommended_guardrail" => "Add or extend workflow lint/security checks so fragile shell and GitHub Actions mistakes fail before review."
    },
    {
      "key" => "parser-cli-contract",
      "title" => "Parser and CLI contract drift",
      "patterns" => [/\bparse\b/, /\bparser\b/, /\bcli\b/, /\bargv\b/, /\bflag\b/, /\bsubstring\b/, /\bcommand\b/],
      "recommended_guardrail" => "Add parser-backed tests that fail when command text, flags, or structured inputs are accepted by substring matching instead of the real parser."
    },
    {
      "key" => "visual-capture-resilience",
      "title" => "Visual capture resilience gap",
      "patterns" => [/\bvisual\b/, /\bsampler\b/, /\bcapture\b/, /\bframe\b/, /\bperception\b/, /\bscreenshot\b/, /\bimage\b/, /\bocr\b/],
      "recommended_guardrail" => "Add capture/perception regression coverage that preserves partial frame results and surfaces provider errors without dropping the whole capture."
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

  def finding_summary(finding)
    finding.slice(
      "repo",
      "pr_number",
      "pr_title",
      "feedback_url",
      "path",
      "line",
      "severity",
      "body_sha256",
      "body_first_line"
    )
  end

  def guardrail_backlog_json(ledger, generated_at: Time.now.utc, sample_limit: 3)
    findings = Array(ledger.fetch("findings"))
    grouped = findings.group_by { |finding| guardrail_class(finding).fetch("key") }
    classes = grouped.map do |key, class_findings|
      metadata = guardrail_class(class_findings.first)
      repos = class_findings.map { |finding| finding.fetch("repo") }.uniq.sort
      findings_by_repo = class_findings.group_by { |finding| finding.fetch("repo") }
      score = class_findings.sum { |finding| severity_score(finding["severity"]) } + ((repos.length - 1) * 10)
      {
        "key" => key,
        "title" => metadata.fetch("title"),
        "score" => score,
        "finding_count" => class_findings.length,
        "repo_count" => repos.length,
        "repos" => repos,
        "recommended_guardrail" => metadata.fetch("recommended_guardrail"),
        "finding_fingerprints" => class_findings.map { |finding| guardrail_finding_fingerprint(finding) }.uniq.sort,
        "repo_fingerprints" => findings_by_repo.transform_values { |repo_findings| repo_findings.map { |finding| guardrail_finding_fingerprint(finding) }.uniq.sort },
        "repo_sample_findings" => findings_by_repo.transform_values { |repo_findings| repo_findings.first(sample_limit).map { |finding| finding_summary(finding) } },
        "sample_findings" => class_findings.first(sample_limit).map { |finding| finding_summary(finding) }
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

  def guardrail_issue_title(entry)
    "#{GUARDRAIL_ISSUE_TITLE_PREFIX} #{entry.fetch("title")} (#{entry.fetch("key")})"
  end

  def repo_guardrail_issue_title(entry)
    "#{REPO_GUARDRAIL_ISSUE_TITLE_PREFIX} #{entry.fetch("title")} (#{entry.fetch("key")})"
  end

  def finding_fingerprint_lines(fingerprints)
    lines = [
      "<!-- evalops-review-feedback-fingerprints:#{fingerprints.to_a.sort.join(",")} -->"
    ]
    fingerprints.to_a.sort.each do |fingerprint|
      lines << "- `#{fingerprint}`"
    end
    lines
  end

  def guardrail_issue_body(backlog, entry)
    lines = [
      "<!-- evalops-review-feedback-guardrail-issue:#{entry.fetch("key")} -->",
      "# #{entry.fetch("title")}",
      "",
      "This issue tracks a recurring review-feedback class from the EvalOps review feedback sentinel.",
      "",
      "- Class: `#{entry.fetch("key")}`",
      "- Score: `#{entry.fetch("score")}`",
      "- Findings: `#{entry.fetch("finding_count")}`",
      "- Repos: `#{entry.fetch("repos").join("`, `")}`",
      "- Generated at: `#{backlog.fetch("generated_at")}`",
      "- Window: merged since `#{backlog.fetch("merged_since")}` with minimum severity `#{backlog.fetch("min_severity")}`",
      "",
      "## Guardrail to build",
      "",
      entry.fetch("recommended_guardrail"),
      "",
      "## Representative feedback",
      ""
    ]

    entry.fetch("sample_findings").each do |finding|
      location = finding["path"] ? "#{finding["path"]}:#{finding["line"] || "?"}" : "top-level feedback"
      lines << "- `#{finding.fetch("severity")}` #{finding.fetch("repo")}##{finding.fetch("pr_number")} #{location}"
      lines << "  - #{finding.fetch("body_first_line")}" unless finding.fetch("body_first_line", "").empty?
      lines << "  - #{finding.fetch("feedback_url")}" if finding["feedback_url"]
    end

    lines.concat(
      [
        "",
        "## Finding fingerprints",
        ""
      ]
    )
    lines.concat(finding_fingerprint_lines(current_guardrail_fingerprints(entry)))

    lines.concat(
      [
        "",
        "## Acceptance criteria",
        "",
        "- The class has an owner repo and a concrete guardrail location.",
        "- The guardrail fails for at least one representative feedback shape listed above.",
        "- The guardrail is wired into the smallest relevant CI or preflight target.",
        "- The issue is closed only after the guardrail has merged and the feedback sentinel no longer ranks this class as an unaddressed candidate."
      ]
    )
    lines.join("\n")
  end

  def repo_sample_findings(entry, repo)
    by_repo = entry.fetch("repo_sample_findings", {})
    return by_repo.fetch(repo) if by_repo.key?(repo)

    entry.fetch("sample_findings").select { |finding| finding.fetch("repo") == repo }
  end

  def repo_guardrail_issue_body(backlog, entry, repo:, org_issue_url: nil)
    repo_findings = repo_sample_findings(entry, repo)
    fingerprints = repo_guardrail_fingerprints(entry, repo)
    lines = [
      "<!-- evalops-review-feedback-repo-guardrail-issue:#{entry.fetch("key")} -->",
      "# #{entry.fetch("title")}",
      "",
      "This issue routes a recurring review-feedback class to the repo that needs the prevention guardrail.",
      "",
      "- Repo: `#{repo}`",
      "- Class: `#{entry.fetch("key")}`",
      "- Repo findings: `#{fingerprints.length}`",
      "- Class findings: `#{entry.fetch("finding_count")}`",
      "- Generated at: `#{backlog.fetch("generated_at")}`",
      "- Window: merged since `#{backlog.fetch("merged_since")}` with minimum severity `#{backlog.fetch("min_severity")}`"
    ]
    lines << "- Org tracker: #{org_issue_url}" if org_issue_url
    lines.concat(
      [
        "",
        "## Guardrail to build",
        "",
        entry.fetch("recommended_guardrail"),
        "",
        "## Representative feedback in this repo",
        ""
      ]
    )

    repo_findings.each do |finding|
      location = finding["path"] ? "#{finding["path"]}:#{finding["line"] || "?"}" : "top-level feedback"
      lines << "- `#{finding.fetch("severity")}` #{finding.fetch("repo")}##{finding.fetch("pr_number")} #{location}"
      lines << "  - #{finding.fetch("body_first_line")}" unless finding.fetch("body_first_line", "").empty?
      lines << "  - #{finding.fetch("feedback_url")}" if finding["feedback_url"]
    end

    lines.concat(
      [
        "",
        "## Finding fingerprints",
        ""
      ]
    )
    lines.concat(finding_fingerprint_lines(fingerprints))

    lines.concat(
      [
        "",
        "## Acceptance criteria",
        "",
        "- A repo-local guardrail fails for at least one representative feedback shape listed above.",
        "- The guardrail is wired into the smallest relevant CI, preflight, or test target in this repo.",
        "- The issue is closed only after the guardrail merges and the feedback sentinel reports this repo/class fingerprint set as already closed or absent."
      ]
    )
    lines.join("\n")
  end

  def find_issue_by_title(repo:, title:)
    stdout, stderr, status = gh(
      "issue",
      "list",
      "--repo",
      repo,
      "--state",
      "all",
      "--search",
      "\"#{title}\" in:title",
      "--limit",
      "10",
      "--json",
      "number,title,state,url,body"
    )
    raise "gh issue list failed: #{stderr.strip}" unless status.success?

    JSON.parse(stdout).find { |issue| issue.fetch("title") == title }
  end

  def guardrail_finding_fingerprint(finding)
    Digest::SHA256.hexdigest(
      [
        finding.fetch("repo"),
        finding.fetch("pr_number").to_s,
        finding["feedback_url"].to_s,
        finding["path"].to_s,
        finding["line"].to_s,
        finding["body_sha256"].to_s.empty? ? Digest::SHA256.hexdigest(finding.fetch("body_first_line", "")) : finding["body_sha256"]
      ].join("\n")
    )
  end

  def guardrail_issue_fingerprints(body)
    body.to_s.scan(/`([0-9a-f]{64})`/).flatten.to_set
  end

  def current_guardrail_fingerprints(entry)
    fingerprints = Array(entry["finding_fingerprints"])
    return fingerprints.to_set unless fingerprints.empty?

    entry.fetch("sample_findings").map { |finding| guardrail_finding_fingerprint(finding) }.to_set
  end

  def repo_guardrail_fingerprints(entry, repo)
    repo_fingerprints = entry.fetch("repo_fingerprints", {})
    fingerprints = Array(repo_fingerprints[repo])
    return fingerprints.to_set unless fingerprints.empty?

    repo_sample_findings(entry, repo).map { |finding| guardrail_finding_fingerprint(finding) }.to_set
  end

  def guardrail_issue_key_from_title(title)
    prefix = "#{GUARDRAIL_ISSUE_TITLE_PREFIX} "
    return nil unless title.to_s.start_with?(prefix)

    match = title.to_s.match(/\(([^()]+)\)\z/)
    match[1] if match
  end

  def upsert_guardrail_class_issue(repo:, backlog:, entry:)
    title = guardrail_issue_title(entry)
    body = guardrail_issue_body(backlog, entry)
    issue = find_issue_by_title(repo: repo, title: title)

    if issue
      number = issue.fetch("number").to_s
      if issue.fetch("state") == "CLOSED"
        issue_fingerprints = guardrail_issue_fingerprints(issue.fetch("body", ""))
        if current_guardrail_fingerprints(entry).subset?(issue_fingerprints)
          return {
            "class_key" => entry.fetch("key"),
            "title" => title,
            "issue_number" => issue.fetch("number"),
            "issue_url" => issue.fetch("url"),
            "action" => "already_closed"
          }
        end

        gh("issue", "reopen", number, "--repo", repo).then do |_out, err, ok|
          raise "gh issue reopen failed: #{err.strip}" unless ok.success?
        end
      end
      gh("issue", "edit", number, "--repo", repo, input: body).then do |_out, err, ok|
        raise "gh issue edit failed: #{err.strip}" unless ok.success?
      end
      return {
        "class_key" => entry.fetch("key"),
        "title" => title,
        "issue_number" => issue.fetch("number"),
        "issue_url" => issue.fetch("url"),
        "action" => issue.fetch("state") == "CLOSED" ? "reopened" : "updated"
      }
    end

    gh("issue", "create", "--repo", repo, "--title", title, input: body).then do |out, err, ok|
      raise "gh issue create failed: #{err.strip}" unless ok.success?

      issue_url = out.strip
      {
        "class_key" => entry.fetch("key"),
        "title" => title,
        "issue_number" => issue_number_from_url(issue_url),
        "issue_url" => issue_url,
        "action" => "created"
      }.compact
    end
  end

  def upsert_repo_guardrail_issue(repo:, backlog:, entry:, org_issue_url: nil)
    title = repo_guardrail_issue_title(entry)
    body = repo_guardrail_issue_body(backlog, entry, repo: repo, org_issue_url: org_issue_url)
    issue = find_issue_by_title(repo: repo, title: title)

    if issue
      number = issue.fetch("number").to_s
      if issue.fetch("state") == "CLOSED"
        issue_fingerprints = guardrail_issue_fingerprints(issue.fetch("body", ""))
        if repo_guardrail_fingerprints(entry, repo).subset?(issue_fingerprints)
          return {
            "scope" => "repo",
            "repo" => repo,
            "class_key" => entry.fetch("key"),
            "title" => title,
            "issue_number" => issue.fetch("number"),
            "issue_url" => issue.fetch("url"),
            "action" => "already_closed"
          }
        end

        gh("issue", "reopen", number, "--repo", repo).then do |_out, err, ok|
          raise "gh issue reopen failed: #{err.strip}" unless ok.success?
        end
      end
      gh("issue", "edit", number, "--repo", repo, input: body).then do |_out, err, ok|
        raise "gh issue edit failed: #{err.strip}" unless ok.success?
      end
      return {
        "scope" => "repo",
        "repo" => repo,
        "class_key" => entry.fetch("key"),
        "title" => title,
        "issue_number" => issue.fetch("number"),
        "issue_url" => issue.fetch("url"),
        "action" => issue.fetch("state") == "CLOSED" ? "reopened" : "updated"
      }
    end

    gh("issue", "create", "--repo", repo, "--title", title, input: body).then do |out, err, ok|
      raise "gh issue create failed: #{err.strip}" unless ok.success?

      issue_url = out.strip
      {
        "scope" => "repo",
        "repo" => repo,
        "class_key" => entry.fetch("key"),
        "title" => title,
        "issue_number" => issue_number_from_url(issue_url),
        "issue_url" => issue_url,
        "action" => "created"
      }.compact
    end
  end

  def upsert_repo_guardrail_issues(backlog:, org_issue_results: [])
    org_issue_by_class = org_issue_results.each_with_object({}) do |result, by_class|
      next unless result["class_key"] && result["issue_url"]

      by_class[result.fetch("class_key")] = result.fetch("issue_url")
    end
    already_closed_classes = org_issue_results
      .select { |result| result["action"] == "already_closed" }
      .map { |result| result.fetch("class_key") }
      .to_set
    backlog.fetch("classes").flat_map do |entry|
      next [] if already_closed_classes.include?(entry.fetch("key"))

      entry.fetch("repos").map do |repo|
        upsert_repo_guardrail_issue(
          repo: repo,
          backlog: backlog,
          entry: entry,
          org_issue_url: org_issue_by_class[entry.fetch("key")]
        )
      end
    end
  end

  def issue_number_from_url(url)
    match = url.to_s.match(%r{/issues/(\d+)\z})
    match[1].to_i if match
  end

  def upsert_guardrail_class_issues(repo:, backlog:)
    backlog.fetch("classes").map do |entry|
      upsert_guardrail_class_issue(repo: repo, backlog: backlog, entry: entry)
    end
  end

  def list_open_guardrail_class_issues(repo:)
    stdout, stderr, status = gh(
      "issue",
      "list",
      "--repo",
      repo,
      "--state",
      "open",
      "--search",
      "\"#{GUARDRAIL_ISSUE_TITLE_PREFIX}\" in:title",
      "--limit",
      "100",
      "--json",
      "number,title,url"
    )
    raise "gh issue list failed: #{stderr.strip}" unless status.success?

    JSON.parse(stdout)
  end

  def close_stale_guardrail_class_issues(repo:, backlog:)
    active_keys = backlog.fetch("classes").map { |entry| entry.fetch("key") }.to_set
    list_open_guardrail_class_issues(repo: repo).each_with_object([]) do |issue, results|
      class_key = guardrail_issue_key_from_title(issue.fetch("title"))
      next if class_key.nil? || active_keys.include?(class_key)

      comment = "Closing because the review feedback sentinel no longer ranks `#{class_key}` as an active guardrail candidate in the current backlog window."
      gh("issue", "close", issue.fetch("number").to_s, "--repo", repo, "--comment", comment).then do |_out, err, ok|
        raise "gh issue close failed: #{err.strip}" unless ok.success?
      end
      result = {
        "class_key" => class_key,
        "title" => issue.fetch("title"),
        "issue_number" => issue.fetch("number"),
        "issue_url" => issue.fetch("url"),
        "action" => "closed_stale"
      }
      results << result
    end
  end

  def guardrail_lifecycle_json(backlog, issue_results:, generated_at: Time.now.utc)
    {
      "schema_version" => GUARDRAIL_LIFECYCLE_SCHEMA_VERSION,
      "source_schema_version" => backlog.fetch("schema_version"),
      "generated_at" => generated_at.utc.iso8601,
      "owner" => backlog.fetch("owner"),
      "merged_since" => backlog.fetch("merged_since"),
      "min_severity" => backlog.fetch("min_severity"),
      "class_count" => backlog.fetch("class_count"),
      "issue_count" => issue_results.length,
      "issues" => issue_results
    }
  end

  def repeat_rate_metrics(ledger, generated_at: Time.now.utc, bucket_days: 7)
    current_start = generated_at.utc - (bucket_days * 24 * 60 * 60)
    previous_start = generated_at.utc - (bucket_days * 2 * 24 * 60 * 60)
    buckets = Hash.new { |hash, key| hash[key] = { "current" => 0, "previous" => 0 } }
    Array(ledger.fetch("findings")).each do |finding|
      merged_at = Time.parse(finding.fetch("merged_at")).utc
      next if merged_at < previous_start || merged_at > generated_at.utc

      class_key = guardrail_class(finding).fetch("key")
      bucket = merged_at >= current_start ? "current" : "previous"
      buckets[class_key][bucket] += 1
    rescue ArgumentError, KeyError
      next
    end

    buckets.map do |class_key, counts|
      current = counts.fetch("current")
      previous = counts.fetch("previous")
      delta = current - previous
      change_percent = if previous.zero?
        current.zero? ? 0 : nil
      else
        ((delta.to_f / previous) * 100).round
      end
      {
        "class_key" => class_key,
        "current_count" => current,
        "previous_count" => previous,
        "delta" => delta,
        "change_percent" => change_percent
      }
    end.sort_by { |entry| [-entry.fetch("current_count"), -entry.fetch("previous_count"), entry.fetch("class_key")] }
  end

  def weekly_guardrail_report_markdown(backlog, lifecycle: nil, ledger: nil, generated_at: Time.now.utc, top_limit: 5)
    classes = backlog.fetch("classes")
    repo_counts = classes.each_with_object(Hash.new(0)) do |entry, counts|
      entry.fetch("repos").each do |repo|
        counts[repo] += Array(entry.fetch("repo_fingerprints", {})[repo]).length
        counts[repo] += repo_sample_findings(entry, repo).length if counts[repo].zero?
        counts[repo] += entry.fetch("finding_count") if counts[repo].zero?
      end
    end.sort_by { |repo, count| [-count, repo] }
    prevented = Array(lifecycle&.fetch("issues", nil)).select { |issue| issue["action"] == "already_closed" }
    repeat_rates = ledger ? repeat_rate_metrics(ledger, generated_at: generated_at) : []
    active = classes.first(top_limit)

    lines = [
      "# Weekly review feedback guardrail report",
      "",
      "- Generated at: `#{generated_at.utc.iso8601}`",
      "- Owner: `#{backlog.fetch("owner")}`",
      "- Window: merged since `#{backlog.fetch("merged_since")}` with minimum severity `#{backlog.fetch("min_severity")}`",
      "- Source findings: `#{backlog.fetch("source_finding_count")}`",
      "- Ranked classes: `#{backlog.fetch("class_count")}`",
      "",
      "<!-- evalops-review-feedback-weekly-report -->"
    ]

    if classes.empty?
      lines << ""
      lines << "No guardrail candidates found in this window."
      return lines.join("\n")
    end

    lines.concat(
      [
        "",
        "## Top guardrail candidates",
        "",
        "| Rank | Class | Score | Findings | Repos | Next guardrail |",
        "| --- | --- | ---: | ---: | --- | --- |"
      ]
    )
    active.each_with_index do |entry, index|
      lines << "| #{index + 1} | `#{entry.fetch("key")}` #{entry.fetch("title")} | #{entry.fetch("score")} | #{entry.fetch("finding_count")} | #{entry.fetch("repos").join(", ")} | #{entry.fetch("recommended_guardrail")} |"
    end

    lines.concat(
      [
        "",
        "## Repos with feedback",
        "",
        "| Repo | Findings in ranked classes |",
        "| --- | ---: |"
      ]
    )
    repo_counts.first(top_limit).each do |repo, count|
      lines << "| #{repo} | #{count} |"
    end

    lines.concat(
      [
        "",
        "## Repeat-rate trend",
        "",
        "| Class | Current 7d | Previous 7d | Delta | Change |",
        "| --- | ---: | ---: | ---: | ---: |"
      ]
    )
    if repeat_rates.empty?
      lines << "| _No dated findings in the last two 7-day buckets_ | 0 | 0 | 0 | 0% |"
    else
      repeat_rates.first(top_limit).each do |entry|
        change = entry.fetch("change_percent").nil? ? "new" : "#{entry.fetch("change_percent")}%"
        lines << "| `#{entry.fetch("class_key")}` | #{entry.fetch("current_count")} | #{entry.fetch("previous_count")} | #{entry.fetch("delta")} | #{change} |"
      end
    end

    lines.concat(
      [
        "",
        "## Newly prevented or suppressed",
        ""
      ]
    )
    if prevented.empty?
      lines << "No already-closed guardrail fingerprints were seen in this run."
    else
      prevented.first(top_limit).each do |issue|
        lines << "- `#{issue.fetch("class_key")}` #{issue.fetch("issue_url")}"
      end
    end

    lines.concat(
      [
        "",
        "## Next actions",
        ""
      ]
    )
    active.each do |entry|
      lines << "- `#{entry.fetch("key")}`: #{entry.fetch("recommended_guardrail")}"
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
    guardrail_issue_repo: nil,
    guardrail_lifecycle_json_output: nil,
    guardrail_repo_issues: false,
    weekly_report_issue_repo: nil,
    weekly_report_issue_title: EvalOpsReviewFeedbackSweep::DEFAULT_WEEKLY_REPORT_TITLE,
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
    parser.on("--guardrail-issue-repo OWNER/REPO", "Create or update one stable issue per ranked guardrail class") { |value| options[:guardrail_issue_repo] = value }
    parser.on("--guardrail-repo-issues", "Create or update repo-local guardrail candidate issues for each ranked class/repo pair") { options[:guardrail_repo_issues] = true }
    parser.on("--guardrail-lifecycle-json-output PATH", "Write guardrail issue lifecycle JSON to this path") { |value| options[:guardrail_lifecycle_json_output] = value }
    parser.on("--weekly-report-issue-repo OWNER/REPO", "Create or comment on this issue repo with the guardrail report") { |value| options[:weekly_report_issue_repo] = value }
    parser.on("--weekly-report-issue-title TITLE", "Issue title for the guardrail report") { |value| options[:weekly_report_issue_title] = value }
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

  backlog = nil
  lifecycle = nil
  if options[:guardrail_backlog_output] || options[:guardrail_backlog_json_output] || options[:guardrail_issue_repo] || options[:guardrail_lifecycle_json_output] || options[:weekly_report_issue_repo]
    backlog = EvalOpsReviewFeedbackSweep.guardrail_backlog_json(ledger)
    File.write(options.fetch(:guardrail_backlog_json_output), "#{JSON.pretty_generate(backlog)}\n") if options[:guardrail_backlog_json_output]
    File.write(options.fetch(:guardrail_backlog_output), "#{EvalOpsReviewFeedbackSweep.guardrail_backlog_markdown(backlog)}\n") if options[:guardrail_backlog_output]
    issue_results = []
    unless options.fetch(:dry_run)
      if options[:guardrail_issue_repo] && backlog.fetch("classes").any?
        issue_results.concat(EvalOpsReviewFeedbackSweep.upsert_guardrail_class_issues(repo: options.fetch(:guardrail_issue_repo), backlog: backlog))
      end
      if options[:guardrail_repo_issues] && backlog.fetch("classes").any?
        issue_results.concat(EvalOpsReviewFeedbackSweep.upsert_repo_guardrail_issues(backlog: backlog, org_issue_results: issue_results))
      end
      issue_results.concat(EvalOpsReviewFeedbackSweep.close_stale_guardrail_class_issues(repo: options.fetch(:guardrail_issue_repo), backlog: backlog)) if options[:guardrail_issue_repo]
    end
    if options[:guardrail_lifecycle_json_output]
      lifecycle = EvalOpsReviewFeedbackSweep.guardrail_lifecycle_json(backlog, issue_results: issue_results)
      File.write(options.fetch(:guardrail_lifecycle_json_output), "#{JSON.pretty_generate(lifecycle)}\n")
    end
    lifecycle ||= EvalOpsReviewFeedbackSweep.guardrail_lifecycle_json(backlog, issue_results: issue_results)
  end

  if options[:weekly_report_issue_repo] && !options.fetch(:dry_run)
    report_body = EvalOpsReviewFeedbackSweep.weekly_guardrail_report_markdown(backlog || EvalOpsReviewFeedbackSweep.guardrail_backlog_json(ledger), lifecycle: lifecycle, ledger: ledger)
    EvalOpsReviewFeedbackSweep.upsert_issue(
      repo: options.fetch(:weekly_report_issue_repo),
      title: options.fetch(:weekly_report_issue_title),
      body: report_body
    )
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
