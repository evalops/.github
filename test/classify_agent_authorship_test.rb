# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "tempfile"

class ClassifyAgentAuthorshipTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, ".github/scripts/classify-agent-authorship.rb")

  def test_untrailered_commits_are_agent_assisted
    outputs = classify([{ "sha" => "abc", "message" => "fix: regular change" }])

    assert_equal "agent-assisted", outputs.fetch("label")
    assert_equal "1", outputs.fetch("total_commits")
    assert_equal "0", outputs.fetch("agent_commits")
    assert_equal "1", outputs.fetch("untrailered_commits")
    assert_equal "0", outputs.fetch("incomplete_agent_commits")
  end

  def test_complete_maestro_trailers_are_agent_authored
    outputs = classify([{ "sha" => "abc", "message" => <<~MSG }])
      feat: ship change

      Co-Authored-By: Maestro <maestro@evalops.dev>
      Maestro-Version: 2026.04.28 / gpt-5
      Maestro-Prompt-Id: prompt-123
      Maestro-Approvals-Id: approval-456
    MSG

    assert_equal "agent-authored", outputs.fetch("label")
    assert_equal "1", outputs.fetch("agent_commits")
    assert_equal "0", outputs.fetch("untrailered_commits")
    assert_equal "0", outputs.fetch("incomplete_agent_commits")
  end

  def test_mixed_authorship_and_incomplete_trailers_are_reported
    outputs = classify(
      [
        { "sha" => "abc", "message" => <<~MSG },
          feat: partial agent change

          Co-Authored-By: Maestro <maestro@evalops.dev>
          Maestro-Version: 2026.04.28 / gpt-5
        MSG
        { "sha" => "def", "message" => "docs: human follow-up" },
      ],
    )

    assert_equal "mixed-authorship", outputs.fetch("label")
    assert_equal "1", outputs.fetch("agent_commits")
    assert_equal "1", outputs.fetch("untrailered_commits")
    assert_equal "1", outputs.fetch("incomplete_agent_commits")
  end

  def test_github_output_file_gets_same_outputs
    Tempfile.create("github-output") do |file|
      outputs = classify(
        [{ "sha" => "abc", "message" => "fix: regular change" }],
        github_output: file.path,
      )
      file_outputs = parse_outputs(File.read(file.path))

      assert_equal outputs, file_outputs
    end
  end

  private

  def classify(commits, github_output: nil)
    input = commits.map(&:to_json).join("\n")
    args = ["ruby", SCRIPT]
    args += ["--github-output", github_output] if github_output
    stdout, stderr, status = Open3.capture3(*args, stdin_data: input)
    assert status.success?, stderr
    parse_outputs(stdout)
  end

  def parse_outputs(text)
    text.each_line(chomp: true).to_h { |line| line.split("=", 2) }
  end
end
