#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "set"
require "time"
require "uri"
require "yaml"

module EvalOpsLabelSync
  SCHEMA_VERSION = "evalops.labels.v1"
  REPORT_SCHEMA_VERSION = "evalops.label_sync_report.v1"
  DEFAULT_OPT_OUT_FILE = ".github/labels-sync.disabled"

  module_function

  def normalize_color(color)
    color.to_s.delete_prefix("#").downcase
  end

  def normalize_description(description)
    description.to_s.strip
  end

  def load_config(path)
    data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    labels = Array(data.fetch("labels"))
    {
      "schema_version" => data["schema_version"],
      "source_repo" => data["source_repo"],
      "sync" => data["sync"] || {},
      "labels" => labels.map do |label|
        {
          "name" => label.fetch("name").to_s,
          "description" => normalize_description(label["description"]),
          "color" => normalize_color(label.fetch("color"))
        }
      end
    }
  end

  def validation_errors(config)
    errors = []
    errors << "schema_version must be #{SCHEMA_VERSION}" unless config["schema_version"] == SCHEMA_VERSION
    names = Set.new
    config.fetch("labels").each do |label|
      name = label.fetch("name")
      errors << "label name is required" if name.empty?
      key = name.downcase
      errors << "duplicate label #{name}" if names.include?(key)
      names << key
      errors << "#{name}: color must be six hex characters" unless label.fetch("color").match?(/\A[0-9a-f]{6}\z/)
    end
    errors
  end

  def parse_repos(value)
    value.to_s.split(",").map(&:strip).reject(&:empty?).map do |repo|
      repo.include?("/") ? repo : "evalops/#{repo}"
    end
  end

  def path_component_escape(value)
    URI.encode_www_form_component(value.to_s).gsub("+", "%20")
  end

  def gh_api(*args, input: nil, allow_failure: false)
    command = ["gh", "api", *args]
    if input
      command += ["-H", "Content-Type: application/json", "--input", "-"]
      stdout, stderr, status = Open3.capture3(*command, stdin_data: input)
    else
      stdout, stderr, status = Open3.capture3(*command)
    end
    return [stdout, stderr, status] if allow_failure

    raise "gh api #{args.join(" ")} failed: #{stderr.empty? ? stdout : stderr}" unless status.success?

    stdout
  end

  def gh_api_json(*args)
    raw = gh_api(*args)
    raw.strip.empty? ? nil : JSON.parse(raw)
  end

  def discover_repos(owner:, include_archived: false)
    stdout, stderr, status = Open3.capture3(
      "gh",
      "repo",
      "list",
      owner,
      "--limit",
      "1000",
      "--json",
      "nameWithOwner,isArchived"
    )
    raise "gh repo list failed: #{stderr.empty? ? stdout : stderr}" unless status.success?

    JSON.parse(stdout).each_with_object([]) do |repo, repos|
      next if repo["isArchived"] && !include_archived

      repos << repo.fetch("nameWithOwner")
    end.sort
  end

  def repo_opted_out?(repo, opt_out_file:)
    path = opt_out_file.split("/").map { |part| path_component_escape(part) }.join("/")
    _stdout, _stderr, status = gh_api("repos/#{repo}/contents/#{path}", allow_failure: true)
    status.success?
  end

  def current_labels(repo)
    Array(gh_api_json("repos/#{repo}/labels?per_page=100")).map do |label|
      {
        "name" => label.fetch("name").to_s,
        "description" => normalize_description(label["description"]),
        "color" => normalize_color(label.fetch("color"))
      }
    end
  end

  def plan_repo(repo:, desired_labels:, existing_labels:, archived: false, opted_out: false)
    result = {
      "repo" => repo,
      "status" => "planned",
      "additions" => [],
      "updates" => [],
      "skips" => [],
      "errors" => []
    }
    if archived
      result["status"] = "skipped"
      result["skips"] << "archived"
      return result
    end
    if opted_out
      result["status"] = "skipped"
      result["skips"] << "opted out"
      return result
    end

    existing_by_name = existing_labels.to_h { |label| [label.fetch("name").downcase, label] }
    desired_labels.each do |desired|
      existing = existing_by_name[desired.fetch("name").downcase]
      if existing.nil?
        result["additions"] << desired
        next
      end

      changes = {}
      if normalize_color(existing["color"]) != desired.fetch("color")
        changes["color"] = {
          "from" => normalize_color(existing["color"]),
          "to" => desired.fetch("color")
        }
      end
      if normalize_description(existing["description"]) != desired.fetch("description")
        changes["description"] = {
          "from" => normalize_description(existing["description"]),
          "to" => desired.fetch("description")
        }
      end
      result["updates"] << desired.merge("changes" => changes) unless changes.empty?
    end
    result["status"] = "in_sync" if result["additions"].empty? && result["updates"].empty?
    result
  end

  def apply_repo_plan(plan)
    repo = plan.fetch("repo")
    plan.fetch("additions").each do |label|
      gh_api(
        "--method",
        "POST",
        "repos/#{repo}/labels",
        input: JSON.generate(
          name: label.fetch("name"),
          color: label.fetch("color"),
          description: label.fetch("description")
        )
      )
    end
    plan.fetch("updates").each do |label|
      encoded = path_component_escape(label.fetch("name"))
      gh_api(
        "--method",
        "PATCH",
        "repos/#{repo}/labels/#{encoded}",
        input: JSON.generate(
          new_name: label.fetch("name"),
          color: label.fetch("color"),
          description: label.fetch("description")
        )
      )
    end
  end

  def build_report(config:, repos:, dry_run:, include_archived:, opt_out_file:)
    labels = config.fetch("labels")
    repo_reports = repos.map do |repo|
      begin
        opted_out = repo_opted_out?(repo, opt_out_file: opt_out_file)
        existing = opted_out ? [] : current_labels(repo)
        plan_repo(repo: repo, desired_labels: labels, existing_labels: existing, opted_out: opted_out)
      rescue StandardError => e
        {
          "repo" => repo,
          "status" => "error",
          "additions" => [],
          "updates" => [],
          "skips" => [],
          "errors" => [e.message]
        }
      end
    end

    {
      "schema_version" => REPORT_SCHEMA_VERSION,
      "generated_at" => Time.now.utc.iso8601,
      "dry_run" => dry_run,
      "include_archived" => include_archived,
      "source_repo" => config["source_repo"],
      "label_count" => labels.length,
      "target_count" => repos.length,
      "additive" => config.dig("sync", "additive") != false,
      "opt_out_file" => opt_out_file,
      "repos" => repo_reports,
      "totals" => {
        "additions" => repo_reports.sum { |repo| repo.fetch("additions").length },
        "updates" => repo_reports.sum { |repo| repo.fetch("updates").length },
        "errors" => repo_reports.sum { |repo| repo.fetch("errors").length },
        "skipped" => repo_reports.count { |repo| repo.fetch("status") == "skipped" },
        "in_sync" => repo_reports.count { |repo| repo.fetch("status") == "in_sync" }
      }
    }
  end

  def markdown_report(report)
    lines = [
      "# EvalOps Label Sync Report",
      "",
      "- Generated at: `#{report.fetch("generated_at")}`",
      "- Mode: `#{report.fetch("dry_run") ? "dry-run" : "apply"}`",
      "- Labels: `#{report.fetch("label_count")}`",
      "- Target repos: `#{report.fetch("target_count")}`",
      "- Additions: `#{report.dig("totals", "additions")}`",
      "- Updates: `#{report.dig("totals", "updates")}`",
      "- Errors: `#{report.dig("totals", "errors")}`",
      "",
      "| Repo | Status | Add | Update | Notes |",
      "| --- | --- | ---: | ---: | --- |"
    ]
    report.fetch("repos").each do |repo|
      notes = (repo.fetch("skips") + repo.fetch("errors")).join("; ")
      lines << "| `#{repo.fetch("repo")}` | #{repo.fetch("status")} | #{repo.fetch("additions").length} | #{repo.fetch("updates").length} | #{notes} |"
    end
    lines.join("\n")
  end

  def run(argv)
    options = {
      labels: "labels.yml",
      owner: "evalops",
      repos: [],
      dry_run: true,
      include_archived: false,
      validate_only: false,
      json_output: nil,
      markdown_output: nil
    }
    OptionParser.new do |parser|
      parser.on("--labels PATH", "Canonical labels YAML") { |value| options[:labels] = value }
      parser.on("--owner OWNER", "GitHub owner for repo discovery") { |value| options[:owner] = value }
      parser.on("--repos REPOS", "Comma-separated repo list") { |value| options[:repos] = parse_repos(value) }
      parser.on("--dry-run", "Plan without applying changes") { options[:dry_run] = true }
      parser.on("--apply", "Apply label additions and updates") { options[:dry_run] = false }
      parser.on("--include-archived", "Include archived repos") { options[:include_archived] = true }
      parser.on("--validate-only", "Validate labels.yml only") { options[:validate_only] = true }
      parser.on("--json-output PATH", "Write JSON report") { |value| options[:json_output] = value }
      parser.on("--markdown-output PATH", "Write Markdown report") { |value| options[:markdown_output] = value }
    end.parse!(argv)

    config = load_config(options.fetch(:labels))
    errors = validation_errors(config)
    unless errors.empty?
      warn errors.join("\n")
      return 1
    end
    return 0 if options[:validate_only]

    repos = options.fetch(:repos)
    repos = discover_repos(owner: options.fetch(:owner), include_archived: options.fetch(:include_archived)) if repos.empty?
    opt_out_file = config.dig("sync", "opt_out_file") || DEFAULT_OPT_OUT_FILE
    report = build_report(
      config: config,
      repos: repos,
      dry_run: options.fetch(:dry_run),
      include_archived: options.fetch(:include_archived),
      opt_out_file: opt_out_file
    )
    unless options.fetch(:dry_run)
      report.fetch("repos").each do |repo_report|
        next unless repo_report.fetch("status") == "planned"

        apply_repo_plan(repo_report)
      end
    end

    json = JSON.pretty_generate(report)
    if options[:json_output]
      File.write(options[:json_output], "#{json}\n")
    else
      puts json
    end
    File.write(options[:markdown_output], "#{markdown_report(report)}\n") if options[:markdown_output]
    report.dig("totals", "errors").positive? ? 1 : 0
  end
end

if $PROGRAM_NAME == __FILE__
  exit EvalOpsLabelSync.run(ARGV)
end
