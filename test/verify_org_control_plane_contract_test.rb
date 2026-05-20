# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../.github/scripts/verify-org-control-plane-contract"

class VerifyOrgControlPlaneContractTest < Minitest::Test
  def test_repo_contract_passes_and_emits_evidence
    contract = EvalOpsOrgControlPlaneContract.load_contract(".github/contracts/org-control-plane.yml")
    report = EvalOpsOrgControlPlaneContract.verify(
      contract,
      root: Dir.pwd,
      generated_at: Time.utc(2026, 5, 15, 12, 0, 0)
    )

    assert_equal "pass", report.fetch("status")
    assert_equal "evalops.github.org-defaults", report.fetch("contract_id")
    assert_operator report.dig("metrics", "requirements_checked"), :>=, 4
    assert_operator report.dig("metrics", "adversarial_fixtures"), :>=, 3
    assert report.fetch("evidence").all? { |item| item.fetch("sha256").match?(/\A[0-9a-f]{64}\z/) }

    markdown = EvalOpsOrgControlPlaneContract.markdown_report(report)
    assert_includes markdown, "Org Control Plane Contract Report"
    assert_includes markdown, "Status: `pass`"
  end

  def test_missing_source_record_fails_closed
    Dir.mktmpdir do |root|
      write_minimal_repo(root)
      contract = EvalOpsOrgControlPlaneContract.load_contract(".github/contracts/org-control-plane.yml")
      contract["provenance"]["source_records"].first["path"] = "missing.md"

      report = EvalOpsOrgControlPlaneContract.verify(contract, root: root)

      assert_equal "fail", report.fetch("status")
      assert_includes report.fetch("errors"), "missing.md does not exist"
    end
  end

  def test_adversarial_fixture_must_fail_closed_or_degrade_safely
    Dir.mktmpdir do |root|
      write_minimal_repo(root)
      contract = EvalOpsOrgControlPlaneContract.load_contract(".github/contracts/org-control-plane.yml")
      contract["adversarial_fixtures"].first["expected_outcome"] = "pass"

      report = EvalOpsOrgControlPlaneContract.verify(contract, root: root)

      assert_equal "fail", report.fetch("status")
      assert report.fetch("errors").any? { |error| error.include?("adversarial expected_outcome") }
    end
  end

  private

  def write_minimal_repo(root)
    paths = [
      "AGENTS.md",
      "README.md",
      "services.yaml",
      ".github/scripts/verify-org-control-plane-contract.rb",
      ".github/scripts/validate-services-catalog.rb",
      ".github/scripts/sweep-recent-review-feedback.rb",
      ".github/scripts/audit-engineering-practices.rb",
      ".github/workflows/codex-rails-check.yml",
      ".github/workflows/engineering-practices-audit.yml",
      ".github/workflows/review-feedback-sentinel.yml",
      "profile/ENGINEERING_PRACTICES.md",
      "test/verify_org_control_plane_contract_test.rb",
      "test/audit_engineering_practices_test.rb",
      "test/validate_services_catalog_test.rb",
      "test/sweep_recent_review_feedback_test.rb",
      "test/evalops_pr_lens_review_test.rb"
    ]
    paths.each do |path|
      absolute = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, "#{path}\n")
    end
  end
end
