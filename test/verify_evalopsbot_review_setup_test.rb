# frozen_string_literal: true

require "minitest/autorun"
require_relative "../.github/scripts/verify-evalopsbot-review-setup"

class VerifyEvalOpsBotReviewSetupTest < Minitest::Test
  def test_contract_passes_offline
    contract = EvalOpsBotReviewSetup.load_contract(".github/evalopsbot-review-targets.yml")
    report = EvalOpsBotReviewSetup.verify(contract, live: false, generated_at: Time.utc(2026, 5, 20, 12, 0, 0))

    assert_equal "pass", report.fetch("status")
    assert_equal "EvalOpsBot", report.fetch("reviewer")
    assert_equal 8, report.fetch("target_repository_count")
    assert_includes report.fetch("central_workflows"), ".github/workflows/evalopsbot-review-canary.yml"
  end

  def test_contract_requires_evalopsbot_reviewer
    contract = EvalOpsBotReviewSetup.load_contract(".github/evalopsbot-review-targets.yml")
    contract["reviewer"] = "someone-else"

    report = EvalOpsBotReviewSetup.verify(contract, live: false)

    assert_equal "fail", report.fetch("status")
    assert_includes report.fetch("errors"), "reviewer must be EvalOpsBot"
  end

  def test_markdown_report_surfaces_errors
    report = {
      "status" => "fail",
      "reviewer" => "EvalOpsBot",
      "central_repo" => "evalops/.github",
      "target_repository_count" => 8,
      "errors" => ["evalops/deploy missing"],
      "warnings" => []
    }

    markdown = EvalOpsBotReviewSetup.markdown_report(report)

    assert_includes markdown, "Status: `fail`"
    assert_includes markdown, "evalops/deploy missing"
  end
end
