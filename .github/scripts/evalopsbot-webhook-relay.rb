#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "optparse"
require "time"
require "uri"

module EvalOpsBotWebhookRelay
  DISPATCH_EVENT = "evalopsbot-review-requested"
  DISPATCH_SOURCE = "evalopsbot-webhook-relay"
  DEFAULT_TARGET_REPO = "evalops/.github"

  module_function

  def secure_compare(left, right)
    return false unless left.bytesize == right.bytesize

    left.bytes.zip(right.bytes).reduce(0) { |memo, pair| memo | (pair.fetch(0) ^ pair.fetch(1)) }.zero?
  end

  def verify_signature!(body:, signature:, secret:)
    return true if secret.to_s.empty?

    expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
    unless signature.to_s.start_with?("sha256=") && secure_compare(signature.to_s, expected)
      raise "invalid GitHub webhook signature"
    end

    true
  end

  def dispatch_payload(event_name:, body:, reviewer:, delivery: nil)
    return skip("unsupported event #{event_name}") unless event_name == "pull_request"

    payload = JSON.parse(body)
    return skip("unsupported action #{payload["action"]}") unless payload["action"] == "review_requested"

    requested_reviewer = payload.dig("requested_reviewer", "login").to_s
    return skip("review requested for #{requested_reviewer}") unless requested_reviewer == reviewer

    repo = payload.dig("repository", "full_name").to_s
    return skip("repository is not in evalops org") unless repo.start_with?("evalops/")

    pr = payload.dig("pull_request", "number")
    return skip("missing pull request number") if pr.nil?

    {
      "event_type" => DISPATCH_EVENT,
      "client_payload" => {
        "target_repo" => repo,
        "target_pr" => "#{repo}##{Integer(pr)}",
        "requested_reviewer" => requested_reviewer,
        "source" => DISPATCH_SOURCE,
        "delivery" => delivery.to_s
      }.reject { |_key, value| value.to_s.empty? }
    }
  rescue JSON::ParserError
    skip("invalid JSON payload")
  end

  def skip(reason)
    {
      "skipped" => true,
      "reason" => reason
    }
  end

  def dispatch_to_github(payload:, token:, target_repo: DEFAULT_TARGET_REPO)
    raise "GITHUB_TOKEN is required" if token.to_s.empty?

    uri = URI("https://api.github.com/repos/#{target_repo}/dispatches")
    request = Net::HTTP::Post.new(uri)
    request["accept"] = "application/vnd.github+json"
    request["authorization"] = "Bearer #{token}"
    request["content-type"] = "application/json"
    request["user-agent"] = "evalopsbot-webhook-relay"
    request.body = JSON.generate(payload)

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end
    unless response.code.to_i.between?(200, 299)
      raise "repository dispatch failed with HTTP #{response.code}: #{response.body}"
    end

    {
      "dispatched" => true,
      "target_repo" => target_repo,
      "event_type" => payload.fetch("event_type"),
      "generated_at" => Time.now.utc.iso8601
    }
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    event_name: ENV["GITHUB_WEBHOOK_EVENT"],
    delivery: ENV["GITHUB_WEBHOOK_DELIVERY"],
    signature: ENV["GITHUB_WEBHOOK_SIGNATURE_256"],
    secret: ENV["GITHUB_WEBHOOK_SECRET"],
    reviewer: "EvalOpsBot",
    token: ENV["GITHUB_TOKEN"],
    target_repo: EvalOpsBotWebhookRelay::DEFAULT_TARGET_REPO,
    dry_run: false
  }
  OptionParser.new do |parser|
    parser.on("--event EVENT") { |value| options[:event_name] = value }
    parser.on("--delivery ID") { |value| options[:delivery] = value }
    parser.on("--signature SIGNATURE") { |value| options[:signature] = value }
    parser.on("--secret SECRET") { |value| options[:secret] = value }
    parser.on("--reviewer LOGIN") { |value| options[:reviewer] = value }
    parser.on("--token TOKEN") { |value| options[:token] = value }
    parser.on("--target-repo OWNER/REPO") { |value| options[:target_repo] = value }
    parser.on("--input PATH") { |value| options[:input] = value }
    parser.on("--output PATH") { |value| options[:output] = value }
    parser.on("--dry-run") { options[:dry_run] = true }
  end.parse!

  body = options[:input] ? File.read(options[:input]) : STDIN.read
  EvalOpsBotWebhookRelay.verify_signature!(
    body: body,
    signature: options[:signature],
    secret: options[:secret]
  )
  payload = EvalOpsBotWebhookRelay.dispatch_payload(
    event_name: options[:event_name],
    body: body,
    reviewer: options[:reviewer],
    delivery: options[:delivery]
  )
  result = if payload["skipped"]
             payload
           elsif options[:dry_run]
             { "would_dispatch" => true, "payload" => payload }
           else
             EvalOpsBotWebhookRelay.dispatch_to_github(
               payload: payload,
               token: options[:token],
               target_repo: options[:target_repo]
             )
           end
  File.write(options[:output], JSON.pretty_generate(result)) if options[:output]
  puts JSON.pretty_generate(result)
end
