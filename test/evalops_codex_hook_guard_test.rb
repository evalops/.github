# frozen_string_literal: true

require "minitest/autorun"
require_relative "../.github/scripts/evalops-codex-hook-guard"

class EvalOpsCodexHookGuardTest < Minitest::Test
  def test_session_start_warns_inside_evalops_repo
    message = EvalOpsCodexHookGuard.session_start_message(
      cwd: "/Users/jonathanhaas/repos/platform",
      remote_url: "git@github.com:evalops/platform.git"
    )

    assert_includes message, "EvalOps repo detected"
    assert_includes message, "bounded one-shot GitHub polling"
  end

  def test_pretool_git_guard_warns_for_destructive_command_in_dirty_tree
    warning = EvalOpsCodexHookGuard.pretool_git_guard(
      command: "git reset --hard origin/main",
      status_text: " M README.md\n"
    )

    assert_includes warning, "Destructive git command"
  end

  def test_pretool_git_guard_allows_clean_worktree
    warning = EvalOpsCodexHookGuard.pretool_git_guard(
      command: "git reset --hard origin/main",
      status_text: ""
    )

    assert_nil warning
  end

  def test_stop_readiness_warns_without_review_thread_evidence
    warning = EvalOpsCodexHookGuard.stop_readiness_warning(
      transcript: "The PR is ready to merge after tests passed."
    )

    assert_includes warning, "no recent review-thread"
  end

  def test_stop_readiness_accepts_review_thread_evidence
    warning = EvalOpsCodexHookGuard.stop_readiness_warning(
      transcript: "Ready to merge after checking GraphQL reviewThreads and statusCheckRollup."
    )

    assert_nil warning
  end
end
