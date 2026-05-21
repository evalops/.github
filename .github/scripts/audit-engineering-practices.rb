#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "optparse"
require "set"
require "time"
require "yaml"

module EvalOpsEngineeringPracticesAudit
  SCHEMA_VERSION = "evalops.engineering_practices.v1"
  REPORT_SCHEMA_VERSION = "evalops.engineering_practices_audit.v1"
  REQUIRED_TOP_LEVEL = %w[
    schema_version
    contract_id
    owner_repo
    workflow
    source_records
    repo_tiers
    practices
    live_audit
  ].freeze
  REQUIRED_PRACTICES = %w[
    org-rulesets
    backlog-lifecycle
    release-train-state
    agent-review-lane
    security-slo
    operating-rails
    evidence-first-done
  ].freeze
  SEARCH_TOTAL_FALLBACK = {
    "total_count" => 0,
    "incomplete_results" => false
  }.freeze
  DEFAULT_FORBIDDEN_CODEQL_PATTERNS = [
    "codeql",
    "code scanning",
    "code-scanning",
    "github/codeql-action"
  ].freeze

  module_function

  def load_contract(path)
    YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
  end

  def relative_path(root, path)
    File.expand_path(path, root)
  end

  def file_digest(root, path)
    absolute = relative_path(root, path)
    return nil unless File.file?(absolute)

    Digest::SHA256.file(absolute).hexdigest
  end

  def repo_name(repo)
    repo.to_s.split("/", 2).last
  end

  def check_path(root, path, errors, warnings, required: true)
    absolute = relative_path(root, path)
    return true if File.file?(absolute)

    message = "#{path} does not exist"
    required ? errors << message : warnings << message
    false
  end

  def duplicates(values)
    seen = Set.new
    values.each_with_object(Set.new) do |value, repeated|
      repeated << value if seen.include?(value)
      seen << value
    end.to_a
  end

  def validate_contract(contract, root: Dir.pwd)
    errors = []
    warnings = []
    REQUIRED_TOP_LEVEL.each { |key| errors << "#{key} is required" unless contract.key?(key) }
    errors << "schema_version must be #{SCHEMA_VERSION}" unless contract["schema_version"] == SCHEMA_VERSION
    errors << "workflow.name is required" if contract.dig("workflow", "name").to_s.empty?
    errors << "workflow.correctness_model is required" if contract.dig("workflow", "correctness_model").to_s.empty?
    errors << "workflow.threat_model is required" if contract.dig("workflow", "threat_model").to_s.empty?

    Array(contract["source_records"]).each do |record|
      errors << "source_records.id is required" if record["id"].to_s.empty?
      path = record["path"].to_s
      errors << "#{record["id"]}: path is required" if path.empty?
      check_path(root, path, errors, warnings) unless path.empty?
    end

    tier_controls = Set.new
    repos_by_tier = contract.fetch("repo_tiers", {}).flat_map do |tier, data|
      errors << "repo_tiers.#{tier}.repos must not be empty" if Array(data["repos"]).empty? && tier != "experimental"
      Array(data["required_controls"]).each { |control| tier_controls << control.to_s }
      Array(data["repos"]).map { |repo| [tier, repo] }
    end
    duplicate_repos = duplicates(repos_by_tier.map(&:last))
    errors << "repo listed in more than one tier: #{duplicate_repos.join(", ")}" unless duplicate_repos.empty?

    practices = Array(contract["practices"])
    practice_ids = practices.map { |practice| practice["id"].to_s }
    duplicate_practices = duplicates(practice_ids)
    errors << "duplicate practice ids: #{duplicate_practices.join(", ")}" unless duplicate_practices.empty?
    missing_practices = REQUIRED_PRACTICES - practice_ids
    errors << "missing required practices: #{missing_practices.join(", ")}" unless missing_practices.empty?
    unknown_controls = tier_controls - Set.new(practice_ids)
    errors << "repo tier references unknown practice controls: #{unknown_controls.to_a.join(", ")}" unless unknown_controls.empty?

    practices.each do |practice|
      id = practice["id"].to_s
      %w[title why adoption].each do |field|
        errors << "#{id}: #{field} is required" if practice[field].to_s.strip.empty?
      end
      source_path = practice.dig("source", "path").to_s
      errors << "#{id}: source.path is required" if source_path.empty?
      check_path(root, source_path, errors, warnings) unless source_path.empty?
      checked_by = Array(practice["checked_by"])
      errors << "#{id}: checked_by is required" if checked_by.empty?
      checked_by.each { |path| check_path(root, path, errors, warnings) }
      errors << "#{id}: at least one signal is required" if Array(practice["signals"]).empty?
    end

    required_files = contract.dig("live_audit", "required_files") || {}
    %w[critical standard].each do |tier|
      errors << "live_audit.required_files.#{tier} is required" unless required_files.key?(tier)
    end
    errors << "live_audit.owner is required" if contract.dig("live_audit", "owner").to_s.empty?
    errors << "live_audit.sampled_repos must not be empty" if Array(contract.dig("live_audit", "sampled_repos")).empty?

    no_codeql = contract.dig("live_audit", "no_codeql") || {}
    errors << "live_audit.no_codeql.security_configuration_id is required" if no_codeql["security_configuration_id"].to_i.zero?
    expected_code_scanning = no_codeql.dig("required_settings", "code_scanning_default_setup").to_s
    errors << "live_audit.no_codeql.required_settings.code_scanning_default_setup must be disabled" unless expected_code_scanning == "disabled"
    excluded_scanners = Array(contract.dig("live_audit", "security_alert_slo", "excluded_scanners")).map(&:to_s)
    errors << "live_audit.security_alert_slo.excluded_scanners must include codeql" unless excluded_scanners.include?("codeql")

    {
      "status" => errors.empty? ? "pass" : "fail",
      "errors" => errors,
      "warnings" => warnings
    }
  end

  def evidence(contract, root)
    Array(contract["source_records"]).map do |record|
      {
        "source_id" => record["id"],
        "path" => record["path"],
        "sha256" => file_digest(root, record["path"])
      }
    end
  end

  def gh_runner
    lambda do |args|
      stdout, stderr, status = Open3.capture3("gh", *args)
      [stdout, stderr, status.success?]
    end
  end

  def parse_json(stdout)
    JSON.parse(stdout)
  rescue JSON::ParserError
    nil
  end

  def run_gh(args, runner, warnings, fallback)
    stdout, stderr, success = runner.call(args)
    unless success
      warnings << "gh #{args.join(" ")} failed: #{stderr.to_s.strip}"
      return fallback
    end
    parsed = parse_json(stdout)
    return parsed unless parsed.nil?

    warnings << "gh #{args.join(" ")} returned non-JSON output"
    fallback
  end

  def search_count(query, runner, warnings)
    payload = run_gh(
      ["api", "-X", "GET", "/search/issues", "-f", "q=#{query}", "-f", "per_page=1"],
      runner,
      warnings,
      SEARCH_TOTAL_FALLBACK
    )
    payload.fetch("total_count", 0)
  end

  def code_search_matches(query, runner, warnings)
    payload = run_gh(
      ["search", "code", query, "--json", "repository,path", "--limit", "100"],
      runner,
      warnings,
      []
    )
    Array(payload).map do |item|
      repository = item.dig("repository", "nameWithOwner") || item.dig("repository", "fullName")
      {
        "repository" => repository.to_s,
        "path" => item["path"].to_s
      }
    end.reject { |item| item["repository"].empty? || item["path"].empty? }
  end

  def org_rulesets(owner, runner, warnings)
    payload = run_gh(
      ["api", "-X", "GET", "/orgs/#{owner}/rulesets"],
      runner,
      warnings,
      []
    )
    Array(payload).map do |ruleset|
      detail = run_gh(
        ["api", "-X", "GET", "/orgs/#{owner}/rulesets/#{ruleset["id"]}"],
        runner,
        warnings,
        ruleset
      )
      {
        "id" => detail["id"],
        "name" => detail["name"],
        "target" => detail["target"],
        "enforcement" => detail["enforcement"],
        "conditions" => detail["conditions"] || {},
        "rules" => Array(detail["rules"]).map do |rule|
          {
            "type" => rule["type"],
            "required_status_checks" => Array(rule.dig("parameters", "required_status_checks")).map do |check|
              check["context"]
            end.compact.sort
          }
        end
      }
    end
  end

  def ruleset_applies_to_repo?(ruleset, repo)
    return false unless ruleset["target"] == "branch"

    repo_name = repo.split("/").last
    condition = ruleset.dig("conditions", "repository_name") || {}
    includes = Array(condition["include"])
    excludes = Array(condition["exclude"])
    included = includes.empty? || includes.include?("~ALL") || includes.include?(repo_name)
    included && !excludes.include?(repo_name)
  end

  def ruleset_required_status_policy(repo, rulesets)
    applicable = Array(rulesets).select { |ruleset| ruleset_applies_to_repo?(ruleset, repo) }
    rules = applicable.map do |ruleset|
      checks = Array(ruleset["rules"]).flat_map { |rule| Array(rule["required_status_checks"]) }.uniq.sort
      next if checks.empty?

      {
        "id" => ruleset["id"],
        "name" => ruleset["name"],
        "enforcement" => ruleset["enforcement"],
        "required_status_checks" => checks
      }
    end.compact
    {
      "ruleset_required_status_checks" => rules.flat_map { |rule| rule["required_status_checks"] }.uniq.sort,
      "ruleset_required_status_check_rulesets" => rules
    }
  end

  def branch_protection(repo, runner, warnings)
    payload = run_gh(
      ["api", "-X", "GET", "/repos/#{repo}/branches/main/protection"],
      runner,
      warnings,
      {}
    )
    contexts = Array(payload.dig("required_status_checks", "contexts")) +
      Array(payload.dig("required_status_checks", "checks")).map { |check| check["context"] }.compact
    {
      "repo" => repo,
      "has_protection" => !payload.empty?,
      "required_status_checks" => contexts.uniq.sort,
      "requires_reviews" => payload.key?("required_pull_request_reviews"),
      "enforce_admins" => payload.dig("enforce_admins", "enabled") == true
    }
  end

  def code_security_default(owner, config_id, runner, warnings)
    defaults = run_gh(
      ["api", "-X", "GET", "/orgs/#{owner}/code-security/configurations/defaults"],
      runner,
      warnings,
      []
    )
    Array(defaults).find { |entry| entry.dig("configuration", "id").to_i == config_id.to_i } || {}
  end

  def code_security_assigned_repositories(owner, config_id, runner, warnings)
    stdout, stderr, success = runner.call(
      [
        "api",
        "--paginate",
        "-X",
        "GET",
        "/orgs/#{owner}/code-security/configurations/#{config_id}/repositories",
        "-f",
        "per_page=100",
        "--jq",
        ".[]"
      ]
    )
    unless success
      warnings << "code-security configuration repository fetch failed: #{stderr.to_s.strip}"
      return []
    end
    entries = stdout.lines.map { |line| parse_json(line) }.compact
    if entries.empty?
      parsed = parse_json(stdout)
      entries = parsed if parsed.is_a?(Array)
    end
    entries = Array(entries).flat_map { |entry| entry.is_a?(Array) ? entry : [entry] }
    entries.map do |entry|
      {
        "repository" => entry.dig("repository", "full_name").to_s,
        "status" => entry["status"].to_s
      }
    end.reject { |entry| entry["repository"].empty? }
  end

  def forbidden_codeql_patterns(config)
    patterns = Array(config["forbidden_required_check_patterns"]).map(&:to_s)
    patterns.empty? ? DEFAULT_FORBIDDEN_CODEQL_PATTERNS : patterns
  end

  def forbidden_codeql_check?(context, patterns)
    normalized = context.to_s.downcase
    patterns.any? { |pattern| normalized.include?(pattern.downcase) }
  end

  def codeql_required_check_matches(branch, patterns)
    Array(branch).flat_map do |item|
      repo = item["repo"]
      branch_checks = Array(item["required_status_checks"]).select { |context| forbidden_codeql_check?(context, patterns) }
      ruleset_checks = Array(item["ruleset_required_status_check_rulesets"]).flat_map do |ruleset|
        Array(ruleset["required_status_checks"]).select { |context| forbidden_codeql_check?(context, patterns) }.map do |context|
          {
            "repo" => repo,
            "source" => "ruleset",
            "ruleset" => ruleset["name"],
            "context" => context
          }
        end
      end
      direct_checks = branch_checks.map do |context|
        {
          "repo" => repo,
          "source" => "branch_protection",
          "context" => context
        }
      end
      direct_checks + ruleset_checks
    end
  end

  def no_codeql_audit(contract, branch, runner, warnings)
    config = contract.dig("live_audit", "no_codeql") || {}
    owner = contract.dig("live_audit", "owner").to_s
    config_id = config["security_configuration_id"].to_i
    default = code_security_default(owner, config_id, runner, warnings)
    assigned = code_security_assigned_repositories(owner, config_id, runner, warnings)
    assigned_by_repo = assigned.to_h { |entry| [entry["repository"], entry["status"]] }
    sampled_repos = Array(contract.dig("live_audit", "sampled_repos")).map(&:to_s)
    missing_sampled = sampled_repos.reject { |repo| assigned_by_repo[repo] == "enforced" }
    workflow_matches = (config["forbidden_workflow_queries"] || {}).map do |key, query|
      {
        "key" => key,
        "query" => query,
        "matches" => code_search_matches(query, runner, warnings)
      }
    end

    configuration = default["configuration"] || {}
    required = config["required_settings"] || {}
    {
      "security_configuration_id" => config_id,
      "configuration_name" => configuration["name"],
      "default_for_new_repos" => default["default_for_new_repos"],
      "required_settings" => required,
      "observed_settings" => {
        "advanced_security" => configuration["advanced_security"],
        "code_scanning_default_setup" => configuration["code_scanning_default_setup"],
        "dependency_graph_autosubmit_action" => configuration["dependency_graph_autosubmit_action"]
      },
      "assigned_repository_count" => assigned.length,
      "missing_sampled_repositories" => missing_sampled,
      "forbidden_workflow_queries" => workflow_matches,
      "forbidden_required_check_patterns" => forbidden_codeql_patterns(config),
      "required_check_matches" => codeql_required_check_matches(branch, forbidden_codeql_patterns(config))
    }
  end

  def file_exists?(repo, path, runner)
    _stdout, _stderr, success = runner.call(["api", "-X", "GET", "/repos/#{repo}/contents/#{path}"])
    success
  end

  def repo_file_adoption(repos, required_by_tier, tiers, runner, owner_repo:, root:)
    repos.map do |repo|
      tier = tiers.fetch(repo, "unknown")
      required = Array(required_by_tier[tier])
      checks = required.to_h do |path|
        present = if repo == owner_repo
                    File.file?(relative_path(root, path))
                  else
                    file_exists?(repo, path, runner)
                  end
        [path, present]
      end
      {
        "repo" => repo,
        "tier" => tier,
        "required_files" => checks,
        "missing_required_files" => checks.select { |_path, present| !present }.keys
      }
    end
  end

  def dependabot_alerts(owner, runner, warnings)
    stdout, stderr, success = runner.call(
      ["api", "--paginate", "-X", "GET", "/orgs/#{owner}/dependabot/alerts", "-f", "state=open", "-f", "per_page=100", "--jq", ".[]"]
    )
    unless success
      warnings << "dependabot alert fetch failed: #{stderr.to_s.strip}"
      return { "total" => 0, "by_severity" => {}, "by_repo" => {} }
    end
    alerts = stdout.lines.map { |line| parse_json(line) }.compact
    if alerts.empty?
      parsed = parse_json(stdout)
      alerts = parsed if parsed.is_a?(Array)
    end
    alerts = Array(alerts)
    critical_high = alerts.select do |alert|
      %w[critical high].include?(alert.dig("security_vulnerability", "severity").to_s)
    end
    {
      "total" => alerts.length,
      "by_severity" => alerts.group_by { |alert| alert.dig("security_vulnerability", "severity").to_s }.transform_values(&:length),
      "by_repo" => alerts.group_by { |alert| alert.dig("repository", "full_name").to_s }.transform_values(&:length),
      "critical_high_by_repo" => critical_high.group_by { |alert| alert.dig("repository", "full_name").to_s }.sort.to_h do |repo, repo_alerts|
        packages = repo_alerts.group_by do |alert|
          [
            alert.dig("security_vulnerability", "severity").to_s,
            alert.dig("dependency", "package", "ecosystem").to_s,
            alert.dig("dependency", "package", "name").to_s
          ]
        end.map do |(severity, ecosystem, name), package_alerts|
          {
            "severity" => severity,
            "ecosystem" => ecosystem,
            "package" => name,
            "count" => package_alerts.length,
            "advisories" => package_alerts.map do |alert|
              alert.dig("security_advisory", "cve_id") || alert.dig("security_advisory", "ghsa_id")
            end.compact.uniq.sort
          }
        end.sort_by { |item| [item["severity"] == "critical" ? 0 : 1, item["ecosystem"], item["package"]] }
        [
          repo,
          {
            "total" => repo_alerts.length,
            "by_severity" => repo_alerts.group_by { |alert| alert.dig("security_vulnerability", "severity").to_s }.transform_values(&:length),
            "packages" => packages
          }
        ]
      end
    }
  end

  def secret_scanning_alerts(owner, runner, warnings)
    stdout, stderr, success = runner.call(
      ["api", "--paginate", "-X", "GET", "/orgs/#{owner}/secret-scanning/alerts", "-f", "state=open", "-f", "per_page=100", "--jq", ".[]"]
    )
    unless success
      warnings << "secret-scanning alert fetch failed: #{stderr.to_s.strip}"
      return { "total" => 0, "by_repo" => {} }
    end
    alerts = stdout.lines.map { |line| parse_json(line) }.compact
    if alerts.empty?
      parsed = parse_json(stdout)
      alerts = parsed if parsed.is_a?(Array)
    end
    alerts = Array(alerts)

    {
      "total" => alerts.length,
      "by_repo" => alerts.group_by { |alert| alert.dig("repository", "full_name").to_s }.sort.to_h do |repo, repo_alerts|
        [
          repo,
          repo_alerts.group_by { |alert| alert["secret_type_display_name"].to_s.empty? ? alert["secret_type"].to_s : alert["secret_type_display_name"].to_s }
            .transform_values(&:length)
            .sort.to_h
        ]
      end
    }
  end

  def issue_list(repo, runner, warnings)
    payload = run_gh(
      ["issue", "list", "--repo", repo, "--state", "open", "--limit", "100", "--json", "number,title,updatedAt"],
      runner,
      warnings,
      []
    )
    Array(payload)
  end

  def stale_closing_comment?(repo, number, runner)
    stdout, _stderr, success = runner.call(
      ["issue", "view", number.to_s, "--repo", repo, "--json", "comments", "--jq", ".comments[-1].body // \"\""]
    )
    return false unless success

    stdout.include?("Closing because")
  end

  def backlog_hygiene(repo, runner, warnings)
    issues = issue_list(repo, runner, warnings).select do |issue|
      issue["title"].to_s.start_with?("[codex] Guardrail backlog:")
    end
    stale = issues.select { |issue| stale_closing_comment?(repo, issue["number"], runner) }
    {
      "repo" => repo,
      "open_guardrail_backlog_issues" => issues.map { |issue| issue.slice("number", "title", "updatedAt") },
      "stale_closing_comments" => stale.map { |issue| issue.slice("number", "title", "updatedAt") }
    }
  end

  def release_train_state(config, runner, warnings)
    repo = config["dashboard_repo"].to_s
    issue = config["dashboard_issue"].to_s
    marker = config["marker"].to_s
    return { "dashboard_present" => false } if repo.empty? || issue.empty?

    payload = run_gh(
      ["issue", "view", issue, "--repo", repo, "--json", "number,title,state,updatedAt,body,url"],
      runner,
      warnings,
      {}
    )
    body = payload["body"].to_s
    {
      "dashboard_repo" => repo,
      "dashboard_issue" => payload["number"] || issue.to_i,
      "dashboard_url" => payload["url"],
      "dashboard_state" => payload["state"],
      "dashboard_updated_at" => payload["updatedAt"],
      "dashboard_present" => !payload.empty? && (marker.empty? || body.include?(marker)),
      "marker" => marker
    }
  end

  def build_findings(report)
    findings = []
    rulesets = report.dig("live", "org_rulesets") || []
    if rulesets.empty?
      findings << {
        "practice" => "org-rulesets",
        "severity" => "high",
        "message" => "No EvalOps org rulesets are configured; repo-local branch protection is carrying all merge policy."
      }
    end

    Array(report.dig("live", "branch_protection")).each do |item|
      next unless item["tier"] == "critical"
      required = Array(item["required_status_checks"]) + Array(item["ruleset_required_status_checks"])
      next unless required.empty?

      findings << {
        "practice" => "org-rulesets",
        "severity" => "medium",
        "repo" => item["repo"],
        "message" => "Critical repo has no required status checks in branch protection or applicable org rulesets."
      }
    end

    Array(report.dig("live", "repo_rails")).each do |item|
      missing = Array(item["missing_required_files"])
      next if missing.empty?

      findings << {
        "practice" => "operating-rails",
        "severity" => item["tier"] == "critical" ? "high" : "medium",
        "repo" => item["repo"],
        "message" => "Missing required rails: #{missing.join(", ")}"
      }
    end

    stale = Array(report.dig("live", "backlog_hygiene", "stale_closing_comments"))
    unless stale.empty?
      findings << {
        "practice" => "backlog-lifecycle",
        "severity" => "medium",
        "message" => "#{stale.length} guardrail backlog issue(s) have closing comments but remain open.",
        "issues" => stale
      }
    end

    security = report.dig("live", "security_alerts") || {}
    critical = security.dig("dependabot", "by_severity", "critical").to_i
    high = security.dig("dependabot", "by_severity", "high").to_i
    if critical.positive? || high.positive?
      findings << {
        "practice" => "security-slo",
        "severity" => critical.positive? ? "high" : "medium",
        "message" => "Open Dependabot alerts exceed zero for critical/high severities.",
        "critical" => critical,
        "high" => high
      }
    end
    secret_open = security.dig("secret_scanning", "total").to_i
    if secret_open.positive?
      findings << {
        "practice" => "security-slo",
        "severity" => "high",
        "message" => "Open secret-scanning alerts require rotation, revocation, false-positive disposition, or accepted-risk evidence.",
        "open" => secret_open
      }
    end

    no_codeql = report.dig("live", "no_codeql") || {}
    required_settings = no_codeql["required_settings"] || {}
    observed_settings = no_codeql["observed_settings"] || {}
    mismatched_settings = required_settings.select do |key, expected|
      observed_settings[key] != expected
    end
    if no_codeql["default_for_new_repos"] != "all" || !mismatched_settings.empty?
      findings << {
        "practice" => "security-slo",
        "severity" => "high",
        "message" => "GitHub CodeQL/default code-scanning baseline drifted from the EvalOps disabled configuration.",
        "configuration_id" => no_codeql["security_configuration_id"],
        "default_for_new_repos" => no_codeql["default_for_new_repos"],
        "mismatched_settings" => mismatched_settings
      }
    end
    unless Array(no_codeql["missing_sampled_repositories"]).empty?
      findings << {
        "practice" => "security-slo",
        "severity" => "high",
        "message" => "Sampled repos are not enforced by the no-CodeQL security configuration.",
        "repos" => no_codeql["missing_sampled_repositories"]
      }
    end
    workflow_matches = Array(no_codeql["forbidden_workflow_queries"]).flat_map { |query| Array(query["matches"]) }
    unless workflow_matches.empty?
      findings << {
        "practice" => "security-slo",
        "severity" => "high",
        "message" => "CodeQL workflow references were found in checked-in workflow paths.",
        "matches" => workflow_matches
      }
    end
    unless Array(no_codeql["required_check_matches"]).empty?
      findings << {
        "practice" => "security-slo",
        "severity" => "high",
        "message" => "CodeQL appears in branch protection or org-ruleset required checks.",
        "matches" => no_codeql["required_check_matches"]
      }
    end

    train_state = report.dig("live", "release_train_state") || {}
    Array(report.dig("live", "release_train_queries")).each do |query|
      next unless query["total_count"].to_i.positive?
      next if query["key"] == "deploy_image_sync_prs" && train_state["dashboard_present"]

      findings << {
        "practice" => "release-train-state",
        "severity" => "medium",
        "message" => "#{query["key"]} matched #{query["total_count"]} merged PR(s) in the audit window without an active release-train state record."
      }
    end

    findings
  end

  def live_audit(contract, runner: gh_runner, root: Dir.pwd, generated_at: Time.now.utc)
    warnings = []
    owner = contract.dig("live_audit", "owner")
    sampled_repos = Array(contract.dig("live_audit", "sampled_repos"))
    tiers = contract.fetch("repo_tiers", {}).each_with_object({}) do |(tier, data), memo|
      Array(data["repos"]).each { |repo| memo[repo] = tier }
    end
    required_files = contract.dig("live_audit", "required_files") || {}

    rulesets = org_rulesets(owner, runner, warnings)
    branch = sampled_repos.map do |repo|
      branch_protection(repo, runner, warnings)
        .merge("tier" => tiers.fetch(repo, "unknown"))
        .merge(ruleset_required_status_policy(repo, rulesets))
    end
    issue_queries = (contract.dig("live_audit", "issue_queries") || {}).map do |key, query|
      { "key" => key, "query" => query, "total_count" => search_count(query, runner, warnings) }
    end
    release_queries = (contract.dig("live_audit", "release_train_queries") || {}).map do |key, query|
      { "key" => key, "query" => query, "total_count" => search_count(query, runner, warnings) }
    end
    train_state = release_train_state(contract.dig("live_audit", "release_train_state") || {}, runner, warnings)
    backlog = backlog_hygiene(contract.fetch("owner_repo"), runner, warnings)
    secret_scanning = secret_scanning_alerts(owner, runner, warnings)
    live = {
      "owner" => owner,
      "org_rulesets" => rulesets,
      "branch_protection" => branch,
      "repo_rails" => repo_file_adoption(
        sampled_repos,
        required_files,
        tiers,
        runner,
        owner_repo: contract.fetch("owner_repo"),
        root: root
      ),
      "issue_queries" => issue_queries,
      "release_train_queries" => release_queries,
      "release_train_state" => train_state,
      "backlog_hygiene" => backlog,
      "security_alerts" => {
        "dependabot" => dependabot_alerts(owner, runner, warnings),
        "secret_scanning" => secret_scanning,
        "secret_scanning_open" => secret_scanning.fetch("total", 0),
        "excluded_scanners" => Array(contract.dig("live_audit", "security_alert_slo", "excluded_scanners"))
      },
      "no_codeql" => no_codeql_audit(contract, branch, runner, warnings)
    }

    static = validate_contract(contract, root: root)
    report = {
      "schema_version" => REPORT_SCHEMA_VERSION,
      "contract_schema_version" => contract["schema_version"],
      "contract_id" => contract["contract_id"],
      "owner_repo" => contract["owner_repo"],
      "generated_at" => generated_at.utc.iso8601,
      "status" => static.fetch("status"),
      "static_validation" => static,
      "evidence" => evidence(contract, root),
      "live" => live,
      "warnings" => warnings
    }
    findings = build_findings(report)
    report["findings"] = findings
    report["status"] = "attention" if report["status"] == "pass" && findings.any?
    report
  end

  def markdown_report(report)
    lines = [
      "# Engineering Practices Audit",
      "",
      "- Contract: `#{report["contract_id"]}`",
      "- Owner: `#{report["owner_repo"]}`",
      "- Generated at: `#{report["generated_at"]}`",
      "- Status: `#{report["status"]}`",
      "",
      "## Findings"
    ]
    findings = Array(report["findings"])
    if findings.empty?
      lines << "No practice drift findings."
    else
      findings.each do |finding|
        prefix = finding["repo"] ? "`#{finding["repo"]}` " : ""
        lines << "- `#{finding["severity"]}` `#{finding["practice"]}` #{prefix}#{finding["message"]}"
      end
    end

    lines << ""
    lines << "## Live Signals"
    rulesets = Array(report.dig("live", "org_rulesets"))
    lines << "- Org rulesets: `#{rulesets.length}`"
    critical = Array(report.dig("live", "branch_protection")).select { |item| item["tier"] == "critical" }
    covered = critical.count do |item|
      (Array(item["required_status_checks"]) + Array(item["ruleset_required_status_checks"])).any?
    end
    lines << "- Critical repo required-check policy: `#{covered}/#{critical.length}`"
    security = report.dig("live", "security_alerts") || {}
    lines << "- Dependabot open alerts: `#{security.dig("dependabot", "total") || 0}`"
    lines << "- Secret scanning open alerts: `#{security.dig("secret_scanning", "total") || security["secret_scanning_open"] || 0}`"
    unless Array(security["excluded_scanners"]).empty?
      lines << "- Excluded scanners: `#{security["excluded_scanners"].join(", ")}`"
    end
    no_codeql = report.dig("live", "no_codeql") || {}
    observed = no_codeql["observed_settings"] || {}
    lines << "- No-CodeQL config: `#{no_codeql["security_configuration_id"] || "unknown"}` default=`#{no_codeql["default_for_new_repos"] || "unknown"}` code_scanning_default_setup=`#{observed["code_scanning_default_setup"] || "unknown"}` assigned_repos=`#{no_codeql["assigned_repository_count"] || 0}`"
    workflow_match_count = Array(no_codeql["forbidden_workflow_queries"]).sum { |query| Array(query["matches"]).length }
    lines << "- CodeQL workflow matches: `#{workflow_match_count}`"
    lines << "- CodeQL required-check matches: `#{Array(no_codeql["required_check_matches"]).length}`"
    Array(report.dig("live", "issue_queries")).each do |query|
      lines << "- #{query["key"]}: `#{query["total_count"]}`"
    end
    Array(report.dig("live", "release_train_queries")).each do |query|
      lines << "- #{query["key"]}: `#{query["total_count"]}`"
    end
    train_state = report.dig("live", "release_train_state") || {}
    if train_state.key?("dashboard_present")
      state = train_state["dashboard_present"] ? "present" : "missing"
      target = train_state["dashboard_url"] || [train_state["dashboard_repo"], train_state["dashboard_issue"]].compact.join("#")
      lines << "- release_train_dashboard: `#{state}` #{target}"
    end

    lines << ""
    lines << "## Missing Repo Rails"
    missing = Array(report.dig("live", "repo_rails")).select { |item| Array(item["missing_required_files"]).any? }
    if missing.empty?
      lines << "No sampled repo rail gaps."
    else
      missing.each do |item|
        lines << "- `#{item["repo"]}` (#{item["tier"]}): #{item["missing_required_files"].join(", ")}"
      end
    end

    dependabot_repos = security.dig("dependabot", "critical_high_by_repo") || {}
    unless dependabot_repos.empty?
      lines << ""
      lines << "## Security Remediation Ledger"
      lines << ""
      lines << "### Critical/High Dependabot Alerts"
      dependabot_repos.each do |repo, data|
        severities = data.fetch("by_severity", {}).map { |severity, count| "#{severity}: #{count}" }.join(", ")
        lines << "- `#{repo}` (#{data.fetch("total", 0)}; #{severities})"
        Array(data["packages"]).first(8).each do |package|
          advisory = Array(package["advisories"]).first(3).join(", ")
          suffix = advisory.empty? ? "" : " - #{advisory}"
          lines << "  - `#{package["severity"]}` `#{package["ecosystem"]}/#{package["package"]}`: #{package["count"]}#{suffix}"
        end
      end
    end

    secret_repos = security.dig("secret_scanning", "by_repo") || {}
    unless secret_repos.empty?
      lines << "" if dependabot_repos.empty?
      lines << "## Security Remediation Ledger" if dependabot_repos.empty?
      lines << ""
      lines << "### Open Secret-Scanning Alerts"
      secret_repos.each do |repo, types|
        type_summary = types.map { |type, count| "#{type}: #{count}" }.join(", ")
        lines << "- `#{repo}`: #{type_summary}"
      end
    end

    unless Array(report["warnings"]).empty?
      lines << ""
      lines << "## Warnings"
      report["warnings"].each { |warning| lines << "- #{warning}" }
    end

    lines.join("\n")
  end

  def write_report(report, json_output, markdown_output, root)
    json = JSON.pretty_generate(report)
    if json_output
      File.write(relative_path(root, json_output), "#{json}\n")
    else
      puts json
    end
    File.write(relative_path(root, markdown_output), "#{markdown_report(report)}\n") if markdown_output
  end

  def run(argv)
    options = {
      contract: ".github/contracts/engineering-practices.yml",
      json_output: nil,
      markdown_output: nil,
      contract_only: false,
      fail_on_findings: false
    }
    OptionParser.new do |parser|
      parser.on("--contract PATH", "Contract YAML path") { |value| options[:contract] = value }
      parser.on("--json-output PATH", "Write JSON report") { |value| options[:json_output] = value }
      parser.on("--markdown-output PATH", "Write Markdown report") { |value| options[:markdown_output] = value }
      parser.on("--contract-only", "Validate the static contract without GitHub API calls") { options[:contract_only] = true }
      parser.on("--fail-on-findings", "Exit non-zero when live practice drift is found") { options[:fail_on_findings] = true }
    end.parse!(argv)

    root = Dir.pwd
    contract = load_contract(relative_path(root, options.fetch(:contract)))
    report = if options[:contract_only]
               static = validate_contract(contract, root: root)
               {
                 "schema_version" => REPORT_SCHEMA_VERSION,
                 "contract_schema_version" => contract["schema_version"],
                 "contract_id" => contract["contract_id"],
                 "owner_repo" => contract["owner_repo"],
                 "generated_at" => Time.now.utc.iso8601,
                 "status" => static.fetch("status"),
                 "static_validation" => static,
                 "evidence" => evidence(contract, root),
                 "findings" => [],
                 "warnings" => static.fetch("warnings")
               }
             else
               live_audit(contract, root: root)
             end

    write_report(report, options[:json_output], options[:markdown_output], root)
    return 1 if report["static_validation"].fetch("status") == "fail"
    return 1 if options[:fail_on_findings] && Array(report["findings"]).any?

    0
  end
end

if $PROGRAM_NAME == __FILE__
  exit EvalOpsEngineeringPracticesAudit.run(ARGV)
end
