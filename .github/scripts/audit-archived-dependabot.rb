#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "time"
require "uri"

module EvalOpsArchivedDependabotAudit
  REPORT_SCHEMA_VERSION = "evalops.archived_dependabot_audit.v1"

  module_function

  def parse_repos(value)
    value.to_s.split(",").map(&:strip).reject(&:empty?).map do |repo|
      repo.include?("/") ? repo : "evalops/#{repo}"
    end
  end

  def gh(*args, allow_failure: false)
    stdout, stderr, status = Open3.capture3("gh", *args)
    return [stdout, stderr, status] if allow_failure

    raise "gh #{args.join(" ")} failed: #{stderr.empty? ? stdout : stderr}" unless status.success?

    stdout
  end

  def discover_archived_repos(owner:)
    raw = gh("repo", "list", owner, "--limit", "1000", "--json", "nameWithOwner,isArchived")
    JSON.parse(raw).each_with_object([]) do |repo, repos|
      repos << repo.fetch("nameWithOwner") if repo["isArchived"]
    end.sort
  end

  def dependabot_config_present?(repo)
    encoded = ".github/dependabot.yml".split("/").map { |part| URI.encode_www_form_component(part) }.join("/")
    _stdout, _stderr, status = gh("api", "repos/#{repo}/contents/#{encoded}", allow_failure: true)
    status.success?
  end

  def open_dependabot_prs(repo)
    raw = gh(
      "pr",
      "list",
      "--repo",
      repo,
      "--state",
      "open",
      "--author",
      "app/dependabot",
      "--json",
      "number,title,url"
    )
    JSON.parse(raw)
  end

  def repo_report(repo)
    {
      "repo" => repo,
      "dependabot_config_present" => dependabot_config_present?(repo),
      "open_dependabot_prs" => open_dependabot_prs(repo)
    }
  rescue StandardError => e
    {
      "repo" => repo,
      "dependabot_config_present" => nil,
      "open_dependabot_prs" => [],
      "error" => e.message
    }
  end

  def report(owner:, repos:)
    rows = repos.map { |repo| repo_report(repo) }
    {
      "schema_version" => REPORT_SCHEMA_VERSION,
      "generated_at" => Time.now.utc.iso8601,
      "owner" => owner,
      "repo_count" => rows.length,
      "repos_with_dependabot_config" => rows.count { |repo| repo["dependabot_config_present"] },
      "open_dependabot_pr_count" => rows.sum { |repo| repo.fetch("open_dependabot_prs").length },
      "repos" => rows
    }
  end

  def markdown_report(report)
    lines = [
      "# Archived Dependabot Audit",
      "",
      "- Generated at: `#{report.fetch("generated_at")}`",
      "- Owner: `#{report.fetch("owner")}`",
      "- Archived repos checked: `#{report.fetch("repo_count")}`",
      "- Repos with Dependabot config: `#{report.fetch("repos_with_dependabot_config")}`",
      "- Open Dependabot PRs: `#{report.fetch("open_dependabot_pr_count")}`",
      "",
      "| Repo | Dependabot config | Open Dependabot PRs | Notes |",
      "| --- | --- | ---: | --- |"
    ]
    report.fetch("repos").each do |repo|
      prs = repo.fetch("open_dependabot_prs").map { |pr| "##{pr.fetch("number")}" }.join(", ")
      lines << "| `#{repo.fetch("repo")}` | #{repo["dependabot_config_present"]} | #{repo.fetch("open_dependabot_prs").length} | #{repo["error"] || prs} |"
    end
    lines.join("\n")
  end

  def run(argv)
    options = {
      owner: "evalops",
      repos: [],
      json_output: nil,
      markdown_output: nil
    }
    OptionParser.new do |parser|
      parser.on("--owner OWNER") { |value| options[:owner] = value }
      parser.on("--repos REPOS") { |value| options[:repos] = parse_repos(value) }
      parser.on("--json-output PATH") { |value| options[:json_output] = value }
      parser.on("--markdown-output PATH") { |value| options[:markdown_output] = value }
    end.parse!(argv)

    repos = options.fetch(:repos)
    repos = discover_archived_repos(owner: options.fetch(:owner)) if repos.empty?
    audit = report(owner: options.fetch(:owner), repos: repos)
    json = JSON.pretty_generate(audit)
    if options[:json_output]
      File.write(options[:json_output], "#{json}\n")
    else
      puts json
    end
    File.write(options[:markdown_output], "#{markdown_report(audit)}\n") if options[:markdown_output]
    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit EvalOpsArchivedDependabotAudit.run(ARGV)
end
