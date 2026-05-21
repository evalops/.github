#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "time"
require "yaml"

module EvalOpsOrgControlPlaneContract
  SCHEMA_VERSION = "evalops.org_control_plane_contract.v1"
  ALLOWED_FIXTURE_OUTCOMES = %w[pass degraded_report fail_closed degraded_safe].freeze
  REQUIRED_EVIDENCE_FIELDS = %w[source_id decision_id output_id].freeze

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

  def check_path(root, path, errors, warnings, required: true)
    absolute = relative_path(root, path)
    return true if File.file?(absolute)

    message = "#{path} does not exist"
    required ? errors << message : warnings << message
    false
  end

  def check_top_level(contract, errors)
    errors << "schema_version must be #{SCHEMA_VERSION}" unless contract["schema_version"] == SCHEMA_VERSION
    %w[contract_id owner_repo workflow requirements provenance slo_gates golden_workflows adversarial_fixtures].each do |key|
      errors << "#{key} is required" unless contract.key?(key)
    end
  end

  def check_requirements(contract, root, errors, warnings)
    Array(contract["requirements"]).each do |requirement|
      id = requirement["id"].to_s
      errors << "requirement id is required" if id.empty?
      source_path = requirement.dig("source", "path")
      errors << "#{id}: source.path is required" if source_path.to_s.empty?
      check_path(root, source_path, errors, warnings) unless source_path.to_s.empty?
      missing_fields = REQUIRED_EVIDENCE_FIELDS - Array(requirement["evidence_fields"]).map(&:to_s)
      errors << "#{id}: evidence_fields missing #{missing_fields.join(", ")}" unless missing_fields.empty?
      Array(requirement["checked_by"]).each do |path|
        check_path(root, path, errors, warnings)
      end
    end
  end

  def check_provenance(contract, root, errors, warnings)
    provenance = contract["provenance"] || {}
    stable_id_pattern = provenance["stable_id_pattern"].to_s
    errors << "provenance.stable_id_pattern is required" if stable_id_pattern.empty?

    source_ids = Array(provenance["source_records"]).map { |record| record["id"] }
    Array(provenance["source_records"]).each do |record|
      errors << "source record id is required" if record["id"].to_s.empty?
      path = record["path"].to_s
      errors << "#{record["id"]}: path is required" if path.empty?
      check_path(root, path, errors, warnings) unless path.empty?
    end

    decision_ids = Array(provenance["derived_decisions"]).map { |record| record["id"] }
    Array(provenance["derived_decisions"]).each do |record|
      check_path(root, record["path"], errors, warnings) if record["path"]
      Array(record["derived_from"]).each do |source_id|
        errors << "#{record["id"]}: unknown source #{source_id}" unless source_ids.include?(source_id)
      end
    end

    Array(provenance["emitted_outputs"]).each do |record|
      errors << "emitted output id is required" if record["id"].to_s.empty?
      produced_by = record["produced_by"].to_s
      errors << "#{record["id"]}: produced_by is required" if produced_by.empty?
      check_path(root, produced_by, errors, warnings) unless produced_by.empty?
    end

    errors << "at least one source record is required" if source_ids.empty?
    errors << "at least one derived decision is required" if decision_ids.empty?
  end

  def check_slo_gates(contract, errors)
    gates = Array(contract["slo_gates"])
    errors << "at least one slo_gate is required" if gates.empty?
    gates.each do |gate|
      id = gate["id"].to_s
      dimensions = Array(gate["dimensions"]).map(&:to_s)
      %w[latency correctness degraded_mode evidence].each do |dimension|
        errors << "#{id}: missing SLO dimension #{dimension}" unless dimensions.include?(dimension)
      end
      errors << "#{id}: fallback is required" if gate["fallback"].to_s.empty?
      errors << "#{id}: success_signal is required" if gate["success_signal"].to_s.empty?
      errors << "#{id}: failure_signal is required" if gate["failure_signal"].to_s.empty?
    end
  end

  def check_github_security_configuration(contract, errors)
    config = contract["github_security_configuration"] || {}
    errors << "github_security_configuration is required" if config.empty?

    errors << "github_security_configuration.id must be 245233" unless config["id"] == 245_233
    errors << "github_security_configuration.default_for_new_repos must be all" unless config["default_for_new_repos"] == "all"

    required = config["required_settings"] || {}
    {
      "advanced_security" => "secret_protection",
      "code_scanning_default_setup" => "disabled",
      "dependency_graph" => "enabled",
      "dependency_graph_autosubmit_action" => "disabled",
      "dependabot_alerts" => "enabled",
      "secret_scanning" => "enabled",
      "secret_scanning_push_protection" => "enabled"
    }.each do |key, expected|
      errors << "github_security_configuration.required_settings.#{key} must be #{expected}" unless required[key] == expected
    end

    forbidden = config["forbidden_workflows"] || {}
    actions = Array(forbidden["actions"])
    generated_paths = Array(forbidden["generated_paths"])
    checked_in_globs = Array(forbidden["checked_in_path_globs"])
    errors << "github_security_configuration.forbidden_workflows.actions must include github/codeql-action" unless actions.include?("github/codeql-action")
    unless generated_paths.include?("dynamic/github-code-scanning/codeql")
      errors << "github_security_configuration.forbidden_workflows.generated_paths must include dynamic/github-code-scanning/codeql"
    end
    unless checked_in_globs.any? { |glob| glob.include?("codeql") }
      errors << "github_security_configuration.forbidden_workflows.checked_in_path_globs must include a codeql glob"
    end
  end

  def check_golden_workflows(contract, root, errors, warnings)
    workflows = Array(contract["golden_workflows"])
    errors << "at least one golden_workflow is required" if workflows.empty?
    workflows.each do |workflow|
      id = workflow["id"].to_s
      %w[workflow verifier].each do |key|
        path = workflow[key].to_s
        errors << "#{id}: #{key} is required" if path.empty?
        check_path(root, path, errors, warnings) unless path.empty?
      end
      Array(workflow["tests"]).each { |path| check_path(root, path, errors, warnings) }
      %w[success_fixture degraded_fixture failure_fixture].each do |key|
        fixture = workflow[key] || {}
        outcome = fixture["expected_outcome"].to_s
        errors << "#{id}: #{key}.expected_outcome is required" if outcome.empty?
        errors << "#{id}: unsupported #{key}.expected_outcome #{outcome}" unless outcome.empty? || ALLOWED_FIXTURE_OUTCOMES.include?(outcome)
      end
    end
  end

  def check_adversarial_fixtures(contract, root, errors, warnings)
    fixtures = Array(contract["adversarial_fixtures"])
    errors << "at least one adversarial_fixture is required" if fixtures.empty?
    categories = fixtures.map { |fixture| fixture["category"].to_s }
    %w[prompt_poisoning tool_poisoning data_poisoning].each do |category|
      errors << "missing adversarial fixture category #{category}" unless categories.include?(category)
    end
    fixtures.each do |fixture|
      id = fixture["id"].to_s
      errors << "adversarial fixture id is required" if id.empty?
      check_path(root, fixture["blocked_by"], errors, warnings) if fixture["blocked_by"]
      outcome = fixture["expected_outcome"].to_s
      unless %w[fail_closed degraded_safe].include?(outcome)
        errors << "#{id}: adversarial expected_outcome must be fail_closed or degraded_safe"
      end
      errors << "#{id}: input is required" if fixture["input"].to_s.empty?
    end
  end

  def evidence(contract, root)
    provenance = contract["provenance"] || {}
    Array(provenance["source_records"]).map do |record|
      {
        "source_id" => record["id"],
        "path" => record["path"],
        "sha256" => file_digest(root, record["path"])
      }
    end
  end

  def verify(contract, root: Dir.pwd, generated_at: Time.now.utc)
    errors = []
    warnings = []
    check_top_level(contract, errors)
    check_requirements(contract, root, errors, warnings)
    check_provenance(contract, root, errors, warnings)
    check_slo_gates(contract, errors)
    check_github_security_configuration(contract, errors)
    check_golden_workflows(contract, root, errors, warnings)
    check_adversarial_fixtures(contract, root, errors, warnings)

    {
      "schema_version" => "#{SCHEMA_VERSION}.report",
      "contract_schema_version" => contract["schema_version"],
      "contract_id" => contract["contract_id"],
      "owner_repo" => contract["owner_repo"],
      "generated_at" => generated_at.iso8601,
      "status" => errors.empty? ? "pass" : "fail",
      "metrics" => {
        "requirements_checked" => Array(contract["requirements"]).length,
        "source_records" => Array(contract.dig("provenance", "source_records")).length,
        "derived_decisions" => Array(contract.dig("provenance", "derived_decisions")).length,
        "emitted_outputs" => Array(contract.dig("provenance", "emitted_outputs")).length,
        "slo_gates" => Array(contract["slo_gates"]).length,
        "github_security_configuration" => contract["github_security_configuration"] ? 1 : 0,
        "golden_workflows" => Array(contract["golden_workflows"]).length,
        "adversarial_fixtures" => Array(contract["adversarial_fixtures"]).length
      },
      "evidence" => evidence(contract, root),
      "errors" => errors,
      "warnings" => warnings
    }
  end

  def markdown_report(report)
    lines = [
      "# Org Control Plane Contract Report",
      "",
      "- Contract: `#{report["contract_id"]}`",
      "- Owner: `#{report["owner_repo"]}`",
      "- Generated at: `#{report["generated_at"]}`",
      "- Status: `#{report["status"]}`",
      "",
      "## Metrics"
    ]
    report.fetch("metrics").each do |key, value|
      lines << "- #{key}: `#{value}`"
    end
    lines << ""
    lines << "## Evidence"
    report.fetch("evidence").each do |item|
      lines << "- `#{item["source_id"]}` #{item["path"]} sha256=#{item["sha256"]}"
    end
    unless report.fetch("errors").empty?
      lines << ""
      lines << "## Errors"
      report.fetch("errors").each { |error| lines << "- #{error}" }
    end
    unless report.fetch("warnings").empty?
      lines << ""
      lines << "## Warnings"
      report.fetch("warnings").each { |warning| lines << "- #{warning}" }
    end
    lines.join("\n")
  end

  def run(argv)
    options = {
      contract: ".github/contracts/org-control-plane.yml",
      json_output: nil,
      markdown_output: nil
    }
    OptionParser.new do |parser|
      parser.on("--contract PATH", "Contract YAML path") { |value| options[:contract] = value }
      parser.on("--json-output PATH", "Write JSON report") { |value| options[:json_output] = value }
      parser.on("--markdown-output PATH", "Write Markdown report") { |value| options[:markdown_output] = value }
    end.parse!(argv)

    root = Dir.pwd
    contract = load_contract(relative_path(root, options.fetch(:contract)))
    report = verify(contract, root: root)
    json = JSON.pretty_generate(report)
    if options[:json_output]
      File.write(relative_path(root, options[:json_output]), "#{json}\n")
    else
      puts json
    end
    File.write(relative_path(root, options[:markdown_output]), "#{markdown_report(report)}\n") if options[:markdown_output]
    report["status"] == "pass" ? 0 : 1
  end
end

if $PROGRAM_NAME == __FILE__
  exit EvalOpsOrgControlPlaneContract.run(ARGV)
end
