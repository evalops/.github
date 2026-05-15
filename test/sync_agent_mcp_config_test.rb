# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../.github/scripts/sync-agent-mcp-config"

class SyncAgentMcpConfigTest < Minitest::Test
  TEMPLATE_DIR = File.expand_path("../.github/agent-mcp/templates", __dir__)

  def test_plan_creates_expected_agent_mcp_files
    Dir.mktmpdir do |workspace|
      plan = EvalOpsAgentMcpConfig.plan(workspace: workspace, template_dir: TEMPLATE_DIR)

      assert_equal(
        [".codex/config.toml", ".cursor/mcp.json", ".gitignore", ".mcp.json", "AGENTS.md"],
        plan.map { |file| file.fetch("path") }.sort
      )
      assert plan.all? { |file| file.fetch("status") == "create" }
    end
  end

  def test_write_is_idempotent_and_preserves_existing_agents_text
    Dir.mktmpdir do |workspace|
      File.write(File.join(workspace, "AGENTS.md"), "# Repo Rails\n\nKeep tests green.\n")

      EvalOpsAgentMcpConfig.write_files(workspace: workspace, template_dir: TEMPLATE_DIR)
      first_agents = File.read(File.join(workspace, "AGENTS.md"))
      EvalOpsAgentMcpConfig.write_files(workspace: workspace, template_dir: TEMPLATE_DIR)
      second_agents = File.read(File.join(workspace, "AGENTS.md"))

      assert_equal first_agents, second_agents
      assert_includes first_agents, "# Repo Rails"
      assert_includes first_agents, "## EvalOps Integration"
      assert_equal "in_sync", EvalOpsAgentMcpConfig.plan(workspace: workspace, template_dir: TEMPLATE_DIR).first.fetch("status")
    end
  end

  def test_gitignore_fragment_adds_env_without_duplicates
    existing = "*.log\n.env\n"
    fragment = ".env\n.env.local\n"

    merged = EvalOpsAgentMcpConfig.merge_gitignore(existing, fragment)

    assert_equal "*.log\n.env\n\n.env.local\n", merged
  end

  def test_markdown_report_lists_file_actions
    report = {
      "generated_at" => "2026-05-15T12:00:00Z",
      "write" => false,
      "totals" => {
        "create" => 1,
        "update" => 0,
        "in_sync" => 4
      },
      "files" => [
        {
          "path" => ".mcp.json",
          "status" => "create",
          "bytes" => 120
        }
      ]
    }

    markdown = EvalOpsAgentMcpConfig.markdown_report(report)

    assert_includes markdown, "EvalOps Agent MCP Config Report"
    assert_includes markdown, "`.mcp.json`"
  end
end
