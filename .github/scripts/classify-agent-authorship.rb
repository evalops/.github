#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

options = {
  github_output: nil,
}

OptionParser.new do |parser|
  parser.on("--github-output PATH", "Append key=value outputs for GitHub Actions") do |path|
    options[:github_output] = path
  end
end.parse!

input = ARGF.read

messages = input.each_line.map do |line|
  next if line.strip.empty?

  parsed = JSON.parse(line)
  if parsed.is_a?(Hash)
    parsed.dig("commit", "message") || parsed["message"]
  end
end.compact

required_patterns = {
  "co_author" => /^Co-Authored-By:\s*Maestro <maestro@evalops\.dev>\s*$/i,
  "version" => /^Maestro-Version:\s*\S.+$/i,
  "prompt_id" => /^Maestro-Prompt-Id:\s*\S.+$/i,
  "approvals_id" => /^Maestro-Approvals-Id:\s*\S.+$/i,
}

marker_pattern = /
  ^Co-Authored-By:\s*Maestro\s+<maestro@evalops\.dev>\s*$ |
  ^Maestro-(?:Version|Prompt-Id|Approvals-Id):
/ix

agent_commits = 0
human_commits = 0
incomplete_commits = 0

messages.each do |message|
  has_marker = message.lines.any? { |line| line.match?(marker_pattern) }

  unless has_marker
    human_commits += 1
    next
  end

  agent_commits += 1
  missing_required = required_patterns.values.any? do |pattern|
    message.lines.none? { |line| line.match?(pattern) }
  end
  incomplete_commits += 1 if missing_required
end

label =
  if agent_commits.positive? && human_commits.positive?
    "mixed-authorship"
  elsif agent_commits.positive?
    "agent-authored"
  else
    "human-authored"
  end

outputs = {
  "label" => label,
  "total_commits" => messages.length,
  "agent_commits" => agent_commits,
  "human_commits" => human_commits,
  "incomplete_agent_commits" => incomplete_commits,
}

outputs.each { |key, value| puts "#{key}=#{value}" }

if options[:github_output]
  File.open(options[:github_output], "a") do |file|
    outputs.each { |key, value| file.puts("#{key}=#{value}") }
  end
end
