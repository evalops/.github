#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "time"

module EvalOpsAgentMcpConfig
  REPORT_SCHEMA_VERSION = "evalops.agent_mcp_config_sync.v1"
  MANAGED_FILES = {
    ".mcp.json" => "mcp.json",
    ".codex/config.toml" => "codex-config.toml",
    ".cursor/mcp.json" => "cursor-mcp.json"
  }.freeze
  AGENTS_HEADING = "## EvalOps Integration"

  module_function

  def read_template(template_dir, name)
    File.read(File.join(template_dir, name)).sub(/\s*\z/, "\n")
  end

  def existing_file(path)
    File.file?(path) ? File.read(path) : nil
  end

  def ensure_trailing_newline(text)
    text.to_s.sub(/\s*\z/, "\n")
  end

  def merge_agents(existing, section)
    return section if existing.to_s.strip.empty?
    return ensure_trailing_newline(existing) if existing.include?(AGENTS_HEADING)

    "#{ensure_trailing_newline(existing)}\n#{section}"
  end

  def merge_gitignore(existing, fragment)
    current = existing.to_s
    additions = fragment.lines.map(&:chomp).reject do |line|
      line.empty? || current.lines.map(&:chomp).include?(line)
    end
    return ensure_trailing_newline(current) if additions.empty?

    base = ensure_trailing_newline(current)
    base = "#{base}\n" unless base.strip.empty?
    "#{base}#{additions.join("\n")}\n"
  end

  def desired_files(workspace:, template_dir:)
    files = {}
    MANAGED_FILES.each do |target, template|
      files[target] = read_template(template_dir, template)
    end
    agents_section = read_template(template_dir, "agents-section.md")
    gitignore_fragment = read_template(template_dir, "gitignore.fragment")
    files["AGENTS.md"] = merge_agents(existing_file(File.join(workspace, "AGENTS.md")), agents_section)
    files[".gitignore"] = merge_gitignore(existing_file(File.join(workspace, ".gitignore")), gitignore_fragment)
    files
  end

  def plan(workspace:, template_dir:)
    desired_files(workspace: workspace, template_dir: template_dir).map do |path, desired|
      absolute = File.join(workspace, path)
      existing = existing_file(absolute)
      status =
        if existing.nil?
          "create"
        elsif ensure_trailing_newline(existing) == desired
          "in_sync"
        else
          "update"
        end
      {
        "path" => path,
        "status" => status,
        "bytes" => desired.bytesize
      }
    end
  end

  def write_files(workspace:, template_dir:)
    desired_files(workspace: workspace, template_dir: template_dir).each do |path, content|
      absolute = File.join(workspace, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, content)
    end
  end

  def report(workspace:, template_dir:, write:)
    file_plan = plan(workspace: workspace, template_dir: template_dir)
    write_files(workspace: workspace, template_dir: template_dir) if write
    {
      "schema_version" => REPORT_SCHEMA_VERSION,
      "generated_at" => Time.now.utc.iso8601,
      "workspace" => workspace,
      "write" => write,
      "files" => file_plan,
      "totals" => {
        "create" => file_plan.count { |file| file.fetch("status") == "create" },
        "update" => file_plan.count { |file| file.fetch("status") == "update" },
        "in_sync" => file_plan.count { |file| file.fetch("status") == "in_sync" }
      }
    }
  end

  def markdown_report(report)
    lines = [
      "# EvalOps Agent MCP Config Report",
      "",
      "- Generated at: `#{report.fetch("generated_at")}`",
      "- Mode: `#{report.fetch("write") ? "write" : "check"}`",
      "- Creates: `#{report.dig("totals", "create")}`",
      "- Updates: `#{report.dig("totals", "update")}`",
      "- In sync: `#{report.dig("totals", "in_sync")}`",
      "",
      "| Path | Status | Bytes |",
      "| --- | --- | ---: |"
    ]
    report.fetch("files").each do |file|
      lines << "| `#{file.fetch("path")}` | #{file.fetch("status")} | #{file.fetch("bytes")} |"
    end
    lines.join("\n")
  end

  def run(argv)
    options = {
      workspace: Dir.pwd,
      template_dir: ".github/agent-mcp/templates",
      write: false,
      json_output: nil,
      markdown_output: nil
    }
    OptionParser.new do |parser|
      parser.on("--workspace PATH", "Repository workspace to check or update") { |value| options[:workspace] = value }
      parser.on("--templates PATH", "Template directory") { |value| options[:template_dir] = value }
      parser.on("--check", "Check only") { options[:write] = false }
      parser.on("--write", "Write missing or drifted files") { options[:write] = true }
      parser.on("--json-output PATH", "Write JSON report") { |value| options[:json_output] = value }
      parser.on("--markdown-output PATH", "Write Markdown report") { |value| options[:markdown_output] = value }
    end.parse!(argv)

    require "fileutils" if options[:write]

    sync_report = report(
      workspace: File.expand_path(options.fetch(:workspace)),
      template_dir: File.expand_path(options.fetch(:template_dir)),
      write: options.fetch(:write)
    )
    json = JSON.pretty_generate(sync_report)
    if options[:json_output]
      File.write(options[:json_output], "#{json}\n")
    else
      puts json
    end
    File.write(options[:markdown_output], "#{markdown_report(sync_report)}\n") if options[:markdown_output]
    needs_change = sync_report.fetch("files").any? { |file| %w[create update].include?(file.fetch("status")) }
    !options.fetch(:write) && needs_change ? 1 : 0
  end
end

if $PROGRAM_NAME == __FILE__
  exit EvalOpsAgentMcpConfig.run(ARGV)
end
