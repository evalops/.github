# frozen_string_literal: true

require "minitest/autorun"
require_relative "../.github/scripts/audit-archived-dependabot"

class AuditArchivedDependabotTest < Minitest::Test
  def test_parse_repos_normalizes_owner
    assert_equal(
      ["evalops/agent-mcp", "evalops/platform"],
      EvalOpsArchivedDependabotAudit.parse_repos("agent-mcp,evalops/platform")
    )
  end

  def test_markdown_report_lists_configs_and_prs
    report = {
      "generated_at" => "2026-05-15T12:00:00Z",
      "owner" => "evalops",
      "repo_count" => 1,
      "repos_with_dependabot_config" => 1,
      "open_dependabot_pr_count" => 2,
      "repos" => [
        {
          "repo" => "evalops/agent-mcp",
          "dependabot_config_present" => true,
          "open_dependabot_prs" => [
            { "number" => 46, "title" => "bump setup-go", "url" => "https://github.com/evalops/agent-mcp/pull/46" },
            { "number" => 47, "title" => "bump internal", "url" => "https://github.com/evalops/agent-mcp/pull/47" }
          ]
        }
      ]
    }

    markdown = EvalOpsArchivedDependabotAudit.markdown_report(report)

    assert_includes markdown, "Archived Dependabot Audit"
    assert_includes markdown, "`evalops/agent-mcp`"
    assert_includes markdown, "#46, #47"
  end
end
