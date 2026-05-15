#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

module EvalOpsCodexHookGuard
  MERGE_WORDS = /\b(merge|merged|mergeable|readiness|ready to merge|ship|land)\b/i
  REVIEW_THREAD_EVIDENCE = /(reviewThreads|review threads|gh api graphql|pullRequest\(number:|statusCheckRollup)/i
  DESTRUCTIVE_GIT = /
    \bgit\s+(
      reset\s+--hard|
      checkout\s+--\s+|
      restore\s+(?:\.|:\/)|
      clean\s+-[^\s]*[fd]
    )\b
  /ix

  module_function

  def evalops_repo?(cwd:, remote_url: nil)
    return true if cwd.to_s.include?("/evalops/") || cwd.to_s.match?(%r{/repos/(platform|deploy|maestro|ensemble|\.github)(/|\z)})

    remote_url.to_s.match?(%r{github\.com[:/]evalops/})
  end

  def session_start_message(cwd:, remote_url: nil)
    return nil unless evalops_repo?(cwd: cwd, remote_url: remote_url)

    [
      "EvalOps repo detected.",
      "Use fresh origin/main for broad sweeps, check live GitHub issues/PRs before org-default changes,",
      "and use bounded one-shot GitHub polling instead of watch loops."
    ].join(" ")
  end

  def dirty_worktree?(status_text)
    status_text.to_s.lines.any? { |line| !line.strip.empty? }
  end

  def destructive_git_command?(command)
    command.to_s.match?(DESTRUCTIVE_GIT)
  end

  def pretool_git_guard(command:, status_text:)
    return nil unless destructive_git_command?(command)
    return nil unless dirty_worktree?(status_text)

    "Destructive git command in a dirty worktree: inspect unrelated changes before running `#{command}`."
  end

  def stop_readiness_warning(transcript:)
    text = transcript.to_s
    return nil unless text.match?(MERGE_WORDS)
    return nil if text.match?(REVIEW_THREAD_EVIDENCE)

    "Task mentions merge/readiness, but no recent review-thread or statusCheckRollup evidence was found."
  end

  def run(argv, env: ENV, stdout: $stdout)
    command = argv.shift.to_s
    options = {}
    OptionParser.new do |parser|
      parser.on("--cwd PATH") { |value| options[:cwd] = value }
      parser.on("--remote-url URL") { |value| options[:remote_url] = value }
      parser.on("--command COMMAND") { |value| options[:command] = value }
      parser.on("--status-text TEXT") { |value| options[:status_text] = value }
      parser.on("--transcript TEXT") { |value| options[:transcript] = value }
      parser.on("--json") { options[:json] = true }
    end.parse!(argv)

    message =
      case command
      when "session-start"
        session_start_message(
          cwd: options[:cwd] || env["PWD"],
          remote_url: options[:remote_url] || env["GIT_REMOTE_URL"]
        )
      when "pretool-git"
        pretool_git_guard(
          command: options[:command] || env["CODEX_TOOL_COMMAND"],
          status_text: options[:status_text] || env["GIT_STATUS_SHORT"]
        )
      when "stop-readiness"
        stop_readiness_warning(transcript: options[:transcript] || env["CODEX_TRANSCRIPT"])
      else
        raise ArgumentError, "unknown hook command #{command.inspect}"
      end

    payload = {
      "hook" => command,
      "message" => message,
      "status" => message ? "warn" : "ok"
    }
    stdout.puts(options[:json] ? JSON.generate(payload) : message) if message || options[:json]
    command == "pretool-git" && message ? 1 : 0
  end
end

if $PROGRAM_NAME == __FILE__
  exit EvalOpsCodexHookGuard.run(ARGV)
end
