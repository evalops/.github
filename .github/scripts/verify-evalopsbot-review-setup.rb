#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "time"
require "yaml"

module EvalOpsBotReviewSetup
  module_function

  def gh_api_json(path)
    stdout, stderr, status = Open3.capture3("gh", "api", path)
    raise "gh api #{path} failed: #{stderr.empty? ? stdout : stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def load_contract(path)
    YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
  end

  def workflow_active?(repo, path)
    encoded = path.split("/").last
    workflow = gh_api_json("repos/#{repo}/actions/workflows/#{encoded}")
    workflow.fetch("path") == path && workflow.fetch("state") == "active"
  rescue StandardError
    false
  end

  def selected_secret_repositories(org:, secret:)
    response = gh_api_json("orgs/#{org}/actions/secrets/#{secret}/repositories?per_page=100")
    Array(response.fetch("repositories", [])).map { |repo| repo.fetch("full_name") }.sort
  rescue StandardError
    []
  end

  def verify(contract, live: true, generated_at: Time.now.utc)
    errors = []
    warnings = []
    org = contract.fetch("org")
    central_repo = contract.fetch("central_repo")
    dispatch_secret = contract.fetch("dispatch_secret")
    target_repos = Array(contract.fetch("target_repositories", []))
    exemptions = Array(contract.fetch("exemptions", []))

    errors << "reviewer must be EvalOpsBot" unless contract.fetch("reviewer") == "EvalOpsBot"
    errors << "target_repositories must not be empty" if target_repos.empty?
    errors << "exemptions must be empty unless an owner and expiry are recorded" unless exemptions.all? do |row|
      row["repo"].to_s.start_with?("#{org}/") && row["owner"].to_s.length.positive? && row["expires"].to_s.length.positive?
    end

    central_workflows = Array(contract.fetch("central_workflows", []))
    central_workflows.each do |path|
      local_path = File.expand_path("../../#{path}", __dir__)
      errors << "missing central workflow #{path}" unless File.exist?(local_path)
    end

    missing_secret_repos = []
    inactive_workflows = []
    if live
      secret_repos = selected_secret_repositories(org: org, secret: dispatch_secret)
      target_repos.each do |target|
        repo = target.fetch("repo")
        fallback_workflow = target.fetch("fallback_workflow")
        missing_secret_repos << repo unless secret_repos.include?(repo)
        inactive_workflows << "#{repo}:#{fallback_workflow}" unless workflow_active?(repo, fallback_workflow)
      end
      central_workflows.each do |path|
        errors << "central workflow #{path} is not active" unless workflow_active?(central_repo, path)
      end
    end

    errors.concat(missing_secret_repos.map { |repo| "#{repo} is missing from #{dispatch_secret} selected repositories" })
    errors.concat(inactive_workflows.map { |entry| "#{entry} is not active" })
    app_secrets = Array(contract.fetch("app_secrets", []))
    warnings << "GitHub App secrets are declared but cannot be value-verified by this audit" unless app_secrets.empty?

    {
      "schema_version" => 1,
      "generated_at" => generated_at.iso8601,
      "status" => errors.empty? ? "pass" : "fail",
      "org" => org,
      "reviewer" => contract.fetch("reviewer"),
      "central_repo" => central_repo,
      "target_repository_count" => target_repos.length,
      "central_workflows" => central_workflows,
      "missing_secret_repositories" => missing_secret_repos,
      "inactive_fallback_workflows" => inactive_workflows,
      "warnings" => warnings,
      "errors" => errors
    }
  end

  def markdown_report(report)
    lines = [
      "## EvalOpsBot Review Setup Audit",
      "",
      "- Status: `#{report.fetch("status")}`",
      "- Reviewer: `#{report.fetch("reviewer")}`",
      "- Central repo: `#{report.fetch("central_repo")}`",
      "- Target repos: #{report.fetch("target_repository_count")}",
      "",
      "### Errors"
    ]
    errors = report.fetch("errors")
    lines.concat(errors.empty? ? ["- None"] : errors.map { |error| "- #{error}" })
    warnings = report.fetch("warnings")
    unless warnings.empty?
      lines << ""
      lines << "### Warnings"
      lines.concat(warnings.map { |warning| "- #{warning}" })
    end
    lines.join("\n")
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    contract: ".github/evalopsbot-review-targets.yml",
    live: true,
    output: "evalopsbot-review-setup-audit.json"
  }
  OptionParser.new do |parser|
    parser.on("--contract PATH") { |value| options[:contract] = value }
    parser.on("--offline") { options[:live] = false }
    parser.on("--output PATH") { |value| options[:output] = value }
    parser.on("--markdown-output PATH") { |value| options[:markdown_output] = value }
  end.parse!

  report = EvalOpsBotReviewSetup.verify(
    EvalOpsBotReviewSetup.load_contract(options.fetch(:contract)),
    live: options.fetch(:live)
  )
  File.write(options.fetch(:output), JSON.pretty_generate(report))
  File.write(options[:markdown_output], EvalOpsBotReviewSetup.markdown_report(report)) if options[:markdown_output]
  puts JSON.pretty_generate(report)
  exit(report.fetch("status") == "pass" ? 0 : 1)
end
