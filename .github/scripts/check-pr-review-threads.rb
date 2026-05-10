#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"

module EvalOpsReviewThreadGuard
  SEVERITY_RANK = {
    "none" => 0,
    "low" => 1,
    "medium" => 2,
    "high" => 3,
    "p1" => 4,
    "p0" => 5
  }.freeze

  module_function

  def severity(body)
    text = body.to_s
    return "p0" if text.match?(/\bP0\b/i)
    return "p1" if text.match?(/\bP1\b/i)
    return "high" if text.match?(/\bHigh Severity\b/i) || text.match?(/!\[High Badge\]/i)
    return "medium" if text.match?(/\bMedium Severity\b/i) || text.match?(/!\[Medium Badge\]/i)
    return "low" if text.match?(/\bLow Severity\b/i) || text.match?(/!\[Low Badge\]/i)

    "none"
  end

  def severity_comment(comments)
    candidates = Array(comments).each_with_object([]) do |comment, matches|
      detected = severity(comment["body"])
      next matches if SEVERITY_RANK.fetch(detected) <= SEVERITY_RANK.fetch("none")

      matches << [detected, comment]
    end
    candidates.max_by { |detected, _comment| SEVERITY_RANK.fetch(detected) }
  end

  def unresolved_threads(payload, min_severity: "high", include_outdated: false)
    threshold = SEVERITY_RANK.fetch(min_severity)
    nodes = payload.dig("data", "repository", "pullRequest", "reviewThreads", "nodes") || []
    nodes.each_with_object([]) do |thread, matches|
      next matches if thread["isResolved"]
      next matches if thread["isOutdated"] && !include_outdated

      detected, comment = severity_comment(thread.dig("comments", "nodes"))
      comment ||= {}
      detected ||= "none"
      next matches if SEVERITY_RANK.fetch(detected) < threshold

      matches << {
        id: thread["id"],
        path: thread["path"],
        line: thread["line"],
        is_outdated: thread["isOutdated"],
        severity: detected,
        url: comment["url"],
        body: comment["body"].to_s
      }
    end
  end

  def graphql_query
    <<~GRAPHQL
      query($owner:String!,$repo:String!,$number:Int!,$after:String) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$number) {
            reviewThreads(first:100, after:$after) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                id
                isResolved
                isOutdated
                path
                line
                comments(first:20) {
                  nodes {
                    body
                    url
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL
  end

  def fetch_payload(repo:, pr:)
    owner, name = repo.split("/", 2)
    nodes = []
    cursor = nil
    first_payload = nil

    loop do
      args = [
        "gh",
        "api",
        "graphql",
        "-f",
        "owner=#{owner}",
        "-f",
        "repo=#{name}",
        "-F",
        "number=#{pr}",
        "-f",
        "query=#{graphql_query}"
      ]
      args += ["-f", "after=#{cursor}"] if cursor
      stdout, stderr, status = Open3.capture3(*args)
      raise "gh api graphql failed: #{stderr.strip}" unless status.success?

      payload = JSON.parse(stdout)
      first_payload ||= payload
      connection = payload.dig("data", "repository", "pullRequest", "reviewThreads") || {}
      nodes.concat(Array(connection["nodes"]))
      page_info = connection["pageInfo"] || {}
      break unless page_info["hasNextPage"]

      cursor = page_info["endCursor"]
      raise "gh api graphql failed: missing reviewThreads endCursor" if cursor.to_s.empty?
    end

    first_payload["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"] = nodes
    first_payload
  end

  def annotation(thread)
    location = [thread.fetch(:path), thread[:line]].compact.join(":")
    title = "unresolved #{thread.fetch(:severity).upcase} review thread"
    "::error file=#{thread.fetch(:path)},line=#{thread[:line] || 1},title=#{title}::#{location} #{thread.fetch(:url)}"
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    min_severity: "high",
    include_outdated: false
  }

  OptionParser.new do |parser|
    parser.on("--repo OWNER/REPO", "Repository to inspect") { |value| options[:repo] = value }
    parser.on("--pr NUMBER", Integer, "Pull request number") { |value| options[:pr] = value }
    parser.on("--min-severity LEVEL", "Minimum severity: low, medium, high, p1, p0") { |value| options[:min_severity] = value.downcase }
    parser.on("--include-outdated", "Include outdated unresolved threads") { options[:include_outdated] = true }
    parser.on("--json PATH", "Read GraphQL payload from a file instead of gh") { |value| options[:json] = value }
  end.parse!

  unless EvalOpsReviewThreadGuard::SEVERITY_RANK.key?(options.fetch(:min_severity))
    warn "invalid --min-severity #{options.fetch(:min_severity).inspect}"
    exit 2
  end

  payload =
    if options[:json]
      JSON.parse(File.read(options.fetch(:json)))
    else
      missing = %i[repo pr].select { |key| options[key].nil? || options[key].to_s.empty? }
      unless missing.empty?
        warn "missing required options: #{missing.join(", ")}"
        exit 2
      end
      EvalOpsReviewThreadGuard.fetch_payload(repo: options.fetch(:repo), pr: options.fetch(:pr))
    end

  threads = EvalOpsReviewThreadGuard.unresolved_threads(
    payload,
    min_severity: options.fetch(:min_severity),
    include_outdated: options.fetch(:include_outdated)
  )

  if threads.empty?
    puts "No unresolved review threads at or above #{options.fetch(:min_severity)} severity."
    exit 0
  end

  warn "Found #{threads.length} unresolved review thread(s) at or above #{options.fetch(:min_severity)} severity:"
  threads.each do |thread|
    warn "- [#{thread.fetch(:severity)}] #{thread.fetch(:path)}:#{thread[:line] || "?"} #{thread.fetch(:url)}"
    puts EvalOpsReviewThreadGuard.annotation(thread)
  end
  exit 1
end
