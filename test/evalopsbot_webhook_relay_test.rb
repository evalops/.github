# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "openssl"
require_relative "../.github/scripts/evalopsbot-webhook-relay"

class EvalOpsBotWebhookRelayTest < Minitest::Test
  def test_dispatch_payload_for_evalopsbot_review_request
    payload = EvalOpsBotWebhookRelay.dispatch_payload(
      event_name: "pull_request",
      reviewer: "EvalOpsBot",
      delivery: "delivery-1",
      body: JSON.generate(
        "action" => "review_requested",
        "requested_reviewer" => { "login" => "EvalOpsBot" },
        "repository" => { "full_name" => "evalops/deploy" },
        "pull_request" => { "number" => 3671 }
      )
    )

    assert_equal "evalopsbot-review-requested", payload.fetch("event_type")
    assert_equal "evalops/deploy#3671", payload.dig("client_payload", "target_pr")
    assert_equal "evalopsbot-webhook-relay", payload.dig("client_payload", "source")
  end

  def test_dispatch_payload_skips_other_reviewers
    result = EvalOpsBotWebhookRelay.dispatch_payload(
      event_name: "pull_request",
      reviewer: "EvalOpsBot",
      body: JSON.generate(
        "action" => "review_requested",
        "requested_reviewer" => { "login" => "someone-else" },
        "repository" => { "full_name" => "evalops/deploy" },
        "pull_request" => { "number" => 1 }
      )
    )

    assert_equal true, result.fetch("skipped")
    assert_includes result.fetch("reason"), "someone-else"
  end

  def test_verify_signature_accepts_github_sha256_signature
    body = JSON.generate("ok" => true)
    signature = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "secret", body)}"

    assert EvalOpsBotWebhookRelay.verify_signature!(
      body: body,
      signature: signature,
      secret: "secret"
    )
  end

  def test_verify_signature_rejects_mismatch
    assert_raises RuntimeError do
      EvalOpsBotWebhookRelay.verify_signature!(
        body: "{}",
        signature: "sha256=bad",
        secret: "secret"
      )
    end
  end
end
