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

  def first_nonblank_line(body)
    body.to_s.lines.map(&:strip).find { |line| !line.empty? }.to_s
  end

  def informational_summary?(body, author: nil)
    first_line = first_nonblank_line(body)
    return false unless first_line.match?(/\A##\s+(PR\s+Summary|Summary|Walkthrough)\b/i)

    author.to_s.match?(/\A(cursor|coderabbitai|chatgpt-codex-connector)\b/i)
  end

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
        kind: "review_thread",
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

  def top_level_feedback(payload, min_severity: "high")
    threshold = SEVERITY_RANK.fetch(min_severity)
    pull_request = payload.dig("data", "repository", "pullRequest") || {}
    current_head_oid = pull_request["headRefOid"].to_s
    feedback = []
    Array(pull_request.dig("comments", "nodes")).each do |comment|
      next if informational_summary?(comment["body"], author: comment.dig("author", "login"))

      detected = severity(comment["body"])
      next if SEVERITY_RANK.fetch(detected) < threshold

      feedback << {
        kind: "pr_comment",
        severity: detected,
        url: comment["url"],
        body: comment["body"].to_s,
        author: comment.dig("author", "login")
      }
    end
    Array(pull_request.dig("reviews", "nodes")).each do |review|
      next if informational_summary?(review["body"], author: review.dig("author", "login"))

      detected = severity(review["body"])
      next if SEVERITY_RANK.fetch(detected) < threshold

      review_commit_oid = review.dig("commit", "oid").to_s
      next if !current_head_oid.empty? && !review_commit_oid.empty? && review_commit_oid != current_head_oid

      feedback << {
        kind: "pr_review",
        severity: detected,
        url: review["url"],
        body: review["body"].to_s,
        author: review.dig("author", "login"),
        state: review["state"]
      }
    end
    feedback
  end

  def blocking_feedback(payload, min_severity: "high", include_outdated: false)
    unresolved_threads(
      payload,
      min_severity: min_severity,
      include_outdated: include_outdated
    ) + top_level_feedback(payload, min_severity: min_severity)
  end

  def merge_pull_request_connections(payload, comments: nil, reviews: nil, review_threads: nil)
    merged = payload.is_a?(Hash) ? payload : {}
    merged["data"] = {} unless merged["data"].is_a?(Hash)
    merged["data"]["repository"] = {} unless merged["data"]["repository"].is_a?(Hash)
    merged["data"]["repository"]["pullRequest"] = {} unless merged["data"]["repository"]["pullRequest"].is_a?(Hash)
    pull_request = merged["data"]["repository"]["pullRequest"]
    if comments
      pull_request["comments"] = {} unless pull_request["comments"].is_a?(Hash)
      pull_request["comments"]["nodes"] = comments
    end
    if reviews
      pull_request["reviews"] = {} unless pull_request["reviews"].is_a?(Hash)
      pull_request["reviews"]["nodes"] = reviews
    end
    if review_threads
      pull_request["reviewThreads"] = {} unless pull_request["reviewThreads"].is_a?(Hash)
      pull_request["reviewThreads"]["nodes"] = review_threads
    end
    merged
  end

  def merge_review_thread_nodes(payload, nodes)
    merge_pull_request_connections(payload, review_threads: nodes)
  end

  def graphql_query
    <<~GRAPHQL
      query($owner:String!,$repo:String!,$number:Int!) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$number) {
            headRefOid
            comments(first:100) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                author {
                  login
                }
                body
                url
              }
            }
            reviews(first:100) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                author {
                  login
                }
                body
                commit {
                  oid
                }
                state
                url
              }
            }
            reviewThreads(first:100) {
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

  def comments_page_query
    <<~GRAPHQL
      query($owner:String!,$repo:String!,$number:Int!,$after:String) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$number) {
            comments(first:100, after:$after) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                author {
                  login
                }
                body
                url
              }
            }
          }
        }
      }
    GRAPHQL
  end

  def reviews_page_query
    <<~GRAPHQL
      query($owner:String!,$repo:String!,$number:Int!,$after:String) {
        repository(owner:$owner, name:$repo) {
          pullRequest(number:$number) {
            reviews(first:100, after:$after) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                author {
                  login
                }
                body
                commit {
                  oid
                }
                state
                url
              }
            }
          }
        }
      }
    GRAPHQL
  end

  def review_threads_page_query
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

  def fetch_graphql(owner:, name:, pr:, query:, cursor: nil)
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
      "query=#{query}"
    ]
    args += ["-f", "after=#{cursor}"] if cursor
    stdout, stderr, status = Open3.capture3(*args)
    raise "gh api graphql failed: #{stderr.strip}" unless status.success?

    JSON.parse(stdout)
  end

  def fetch_connection_tail(owner:, name:, pr:, query:, connection_name:, first_connection:)
    nodes = []
    connection = first_connection || {}
    page_info = connection["pageInfo"] || {}
    while page_info["hasNextPage"]
      cursor = page_info["endCursor"]
      raise "gh api graphql failed: missing #{connection_name} endCursor" if cursor.to_s.empty?

      payload = fetch_graphql(owner: owner, name: name, pr: pr, query: query, cursor: cursor)
      connection = payload.dig("data", "repository", "pullRequest", connection_name) || {}
      nodes.concat(Array(connection["nodes"]))
      page_info = connection["pageInfo"] || {}
    end
    nodes
  end

  def fetch_payload(repo:, pr:)
    owner, name = repo.split("/", 2)
    payload = fetch_graphql(owner: owner, name: name, pr: pr, query: graphql_query)
    pull_request = payload.dig("data", "repository", "pullRequest") || {}
    comments_connection = pull_request["comments"] || {}
    reviews_connection = pull_request["reviews"] || {}
    threads_connection = pull_request["reviewThreads"] || {}

    comments = Array(comments_connection["nodes"]) + fetch_connection_tail(
      owner: owner,
      name: name,
      pr: pr,
      query: comments_page_query,
      connection_name: "comments",
      first_connection: comments_connection
    )
    reviews = Array(reviews_connection["nodes"]) + fetch_connection_tail(
      owner: owner,
      name: name,
      pr: pr,
      query: reviews_page_query,
      connection_name: "reviews",
      first_connection: reviews_connection
    )
    review_threads = Array(threads_connection["nodes"]) + fetch_connection_tail(
      owner: owner,
      name: name,
      pr: pr,
      query: review_threads_page_query,
      connection_name: "reviewThreads",
      first_connection: threads_connection
    )

    merge_pull_request_connections(
      payload,
      comments: comments,
      reviews: reviews,
      review_threads: review_threads
    )
  end

  def annotation(thread)
    unless thread[:path]
      title = "unresolved #{thread.fetch(:severity).upcase} #{thread.fetch(:kind).tr("_", " ")}"
      return "::error title=#{title}::#{thread.fetch(:url)}"
    end

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

  feedback = EvalOpsReviewThreadGuard.blocking_feedback(
    payload,
    min_severity: options.fetch(:min_severity),
    include_outdated: options.fetch(:include_outdated)
  )

  if feedback.empty?
    puts "No unresolved PR feedback at or above #{options.fetch(:min_severity)} severity."
    exit 0
  end

  warn "Found #{feedback.length} unresolved PR feedback item(s) at or above #{options.fetch(:min_severity)} severity:"
  feedback.each do |thread|
    location = thread[:path] ? "#{thread.fetch(:path)}:#{thread[:line] || "?"}" : thread.fetch(:kind).to_s
    warn "- [#{thread.fetch(:severity)}] #{location} #{thread.fetch(:url)}"
    puts EvalOpsReviewThreadGuard.annotation(thread)
  end
  exit 1
end
