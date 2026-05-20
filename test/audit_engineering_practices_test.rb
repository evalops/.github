# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "time"
require_relative "../.github/scripts/audit-engineering-practices"

class AuditEngineeringPracticesTest < Minitest::Test
  def test_static_contract_passes_and_emits_source_evidence
    contract = EvalOpsEngineeringPracticesAudit.load_contract(".github/contracts/engineering-practices.yml")
    validation = EvalOpsEngineeringPracticesAudit.validate_contract(contract, root: Dir.pwd)

    assert_equal "pass", validation.fetch("status"), validation.fetch("errors").join("\n")
    evidence = EvalOpsEngineeringPracticesAudit.evidence(contract, Dir.pwd)
    assert evidence.all? { |item| item.fetch("sha256").match?(/\A[0-9a-f]{64}\z/) }
  end

  def test_missing_required_practice_fails_static_validation
    contract = EvalOpsEngineeringPracticesAudit.load_contract(".github/contracts/engineering-practices.yml")
    contract["practices"].reject! { |practice| practice["id"] == "security-slo" }

    validation = EvalOpsEngineeringPracticesAudit.validate_contract(contract, root: Dir.pwd)

    assert_equal "fail", validation.fetch("status")
    assert validation.fetch("errors").any? { |error| error.include?("missing required practices: security-slo") }
  end

  def test_live_audit_reports_ruleset_rail_backlog_security_and_release_findings
    contract = EvalOpsEngineeringPracticesAudit.load_contract(".github/contracts/engineering-practices.yml")
    runner = FakeGhRunner.new

    report = EvalOpsEngineeringPracticesAudit.live_audit(
      contract,
      runner: runner,
      root: Dir.pwd,
      generated_at: Time.utc(2026, 5, 20, 4, 0, 0)
    )

    assert_equal "attention", report.fetch("status")
    findings = report.fetch("findings")
    assert findings.any? { |finding| finding.fetch("practice") == "org-rulesets" }
    assert findings.any? { |finding| finding.fetch("practice") == "operating-rails" && finding.fetch("repo") == "evalops/platform" }
    assert findings.any? { |finding| finding.fetch("practice") == "backlog-lifecycle" }
    assert findings.any? { |finding| finding.fetch("practice") == "security-slo" }
    assert findings.any? { |finding| finding.fetch("practice") == "release-train-state" }

    markdown = EvalOpsEngineeringPracticesAudit.markdown_report(report)
    assert_includes markdown, "Engineering Practices Audit"
    assert_includes markdown, "Missing Repo Rails"
    JSON.parse(JSON.pretty_generate(report))
  end

  def test_required_status_ruleset_satisfies_critical_repo_policy
    contract = EvalOpsEngineeringPracticesAudit.load_contract(".github/contracts/engineering-practices.yml")
    contract["live_audit"]["sampled_repos"] = ["evalops/platform"]
    contract["repo_tiers"]["critical"]["repos"] = ["evalops/platform"]
    runner = RulesetPolicyGhRunner.new

    report = EvalOpsEngineeringPracticesAudit.live_audit(
      contract,
      runner: runner,
      root: Dir.pwd,
      generated_at: Time.utc(2026, 5, 20, 4, 0, 0)
    )

    policy = report.dig("live", "branch_protection").fetch(0)
    assert_equal ["ci"], policy.fetch("ruleset_required_status_checks")
    refute report.fetch("findings").any? { |finding| finding.fetch("practice") == "org-rulesets" }
  end

  class FakeGhRunner
    def initialize
      @files = {
        "evalops/platform" => {
          "AGENTS.md" => true,
          ".github/workflows/review-thread-guard.yml" => true
        },
        "evalops/deploy" => {
          "AGENTS.md" => true,
          ".github/CODEOWNERS" => true,
          ".github/workflows/review-thread-guard.yml" => true,
          ".github/workflows/evalopsbot-review-request.yml" => true,
          ".github/workflows/codex-rails-check.yml" => true
        }
      }
    end

    def call(args)
      command = args.join(" ")
      return json([]) if command == "api -X GET /orgs/evalops/rulesets"
      return json(branch_protection(args)) if command.include?("/branches/main/protection")
      return content_response(args) if command.include?("/contents/")
      return search_response(args) if command.start_with?("api -X GET /search/issues")
      return issue_list_response if command.start_with?("issue list")
      return ["Closing because the sentinel no longer ranks this class.\n", "", true] if command.start_with?("issue view 69")
      return [JSON.generate(dependabot_alert) + "\n", "", true] if command.include?("/dependabot/alerts")
      return ["{}\n{}\n", "", true] if command.include?("/secret-scanning/alerts")
      raise "audit must not fetch code scanning alerts" if command.include?("/code-scanning/alerts")

      json({})
    end

    private

    def json(value)
      [JSON.generate(value), "", true]
    end

    def branch_protection(args)
      repo = args.find { |arg| arg.start_with?("/repos/") }.split("/")[2, 2].join("/")
      return {} if repo == "evalops/platform"

      {
        "required_status_checks" => {
          "contexts" => ["ci"]
        },
        "required_pull_request_reviews" => {},
        "enforce_admins" => {
          "enabled" => true
        }
      }
    end

    def content_response(args)
      path = args.find { |arg| arg.start_with?("/repos/") }
      parts = path.split("/")
      repo = parts[2, 2].join("/")
      file = parts[5, parts.length].join("/")
      present = @files.fetch(repo, {}).fetch(file, false)
      present ? json({ "path" => file }) : ["", "not found", false]
    end

    def search_response(args)
      query_arg = args.find { |arg| arg.start_with?("q=") }.to_s
      count = if query_arg.include?("Hold prod-continuous")
                4
              elsif query_arg.include?("Guardrail candidate")
                2
              else
                0
              end
      json({ "total_count" => count, "incomplete_results" => false })
    end

    def issue_list_response
      json(
        [
          {
            "number" => 69,
            "title" => "[codex] Guardrail backlog: Workflow shell footgun (workflow-shell-footgun)",
            "updatedAt" => "2026-05-20T01:22:06Z"
          }
        ]
      )
    end

    def dependabot_alert
      {
        "repository" => {
          "full_name" => "evalops/platform"
        },
        "security_vulnerability" => {
          "severity" => "high"
        }
      }
    end
  end

  class RulesetPolicyGhRunner
    def call(args)
      command = args.join(" ")
      return json([ruleset_summary]) if command == "api -X GET /orgs/evalops/rulesets"
      return json(ruleset_detail) if command == "api -X GET /orgs/evalops/rulesets/1"
      return json({}) if command.include?("/branches/main/protection")
      return json({ "path" => "ok" }) if command.include?("/contents/")
      return json({ "total_count" => 0, "incomplete_results" => false }) if command.start_with?("api -X GET /search/issues")
      return json([]) if command.start_with?("issue list")
      return ["", "", true] if command.start_with?("issue view")
      return ["", "", true] if command.include?("/dependabot/alerts")
      return ["", "", true] if command.include?("/secret-scanning/alerts")

      json({})
    end

    private

    def json(value)
      [JSON.generate(value), "", true]
    end

    def ruleset_summary
      {
        "id" => 1,
        "name" => "EvalOps platform required checks (evaluate)",
        "target" => "branch",
        "enforcement" => "evaluate"
      }
    end

    def ruleset_detail
      ruleset_summary.merge(
        "conditions" => {
          "repository_name" => {
            "include" => ["platform"],
            "exclude" => []
          },
          "ref_name" => {
            "include" => ["~DEFAULT_BRANCH"],
            "exclude" => []
          }
        },
        "rules" => [
          {
            "type" => "required_status_checks",
            "parameters" => {
              "required_status_checks" => [
                {
                  "context" => "ci"
                }
              ]
            }
          }
        ]
      )
    end
  end
end
