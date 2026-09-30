# frozen_string_literal: true

require_relative 'local_review_batch_fixture'

# Real runner and fake CLI processes exercise prompt isolation and concurrent ledger writes.
class LocalReviewBatchTest < Minitest::Test
  COMMAND = LocalReviewCodexTest::COMMAND
  include LocalReviewBatchFixture

  def test_same_head_peers_hide_current_findings
    in_loop do |head|
      first = batch_review(head, 'openai/codex', findings: 1)
      second = batch_review(head, 'anthropic/claude', findings: 1)
      refute_includes File.read(trace('anthropic/claude')), 'PRIOR ROUNDS:'
      assert_equal([1, 2], [first, second].map { |result| result.fetch('round') })
      assert_ledger_rounds([head, head])
      assert_refused(head, 'already reviewed')
    end
  end

  def test_requires_every_disposition_and_supplies_all_prior_findings
    in_loop do |head|
      findings_batch(head)
      fix = fix_commit
      disposition(1, fix:)
      assert_refused(fix, 'Record round 2')
      disposition(2)
      batch_review(fix, 'anthropic/claude')
      assert_prior_batch('anthropic/claude')
    end
  end

  def test_sequential_peers_receive_the_same_prior_batch
    in_loop do |head|
      findings_batch(head)
      fix = fix_commit
      disposition(1, fix:)
      disposition(2)
      batch_review(fix, 'anthropic/claude')
      batch_review(fix, 'openai/codex')
      assert_equal prior_prompt('anthropic/claude'), prior_prompt('openai/codex')
    end
  end

  def test_checks_fixes_from_every_peer_in_the_previous_batch
    in_loop do |head|
      batch_review(head, 'openai/codex', findings: 1)
      batch_review(head, 'anthropic/claude')
      git!(@root, 'checkout', '--quiet', '-b', 'side')
      side = fix_commit
      git!(@root, 'checkout', '--quiet', '-')
      disposition(1, fix: side)
      commit!(@root, 'unrelated', 'Unrelated change')
      assert_refused(git!(@root, 'rev-parse', 'HEAD').strip, "does not build on #{side}")
    end
  end

  def test_record_requires_an_explicit_batch_round
    in_loop do |head|
      findings_batch(head)
      error = assert_raises(Shaka::Error) { ledger.record!({ 'findings' => [finding(1)] }) }
      assert_includes error.message, '--round'
    end
  end

  def test_record_rejects_a_stale_target
    in_loop do |head|
      findings_batch(head)
      error = assert_raises(Shaka::Error) do
        ledger.record!({ 'head' => 'f' * 40, 'findings' => [finding(1)] }, number: 1)
      end
      assert_includes error.message, 'head does not match'
    end
  end

  def test_concurrent_dispositions_preserve_peers_and_freeze_prior_batches
    in_loop do |head|
      findings_batch(head)
      concurrent_dispositions
      assert(ledger.rounds.all? { |round| round.fetch('findings').size == 1 })
      batch_review(fix_commit, 'openai/codex')
      assert_raises(Shaka::Error) { ledger.record!({ 'findings' => [finding(1)] }, number: 1) }
    end
  end

  def test_refuses_a_changed_base_even_for_a_same_head_peer
    in_loop do |head|
      batch_review(head, 'anthropic/claude')
      @base = head
      assert_refused(head, 'measure the change against')
    end
  end
end

# Concurrent reviewer completion can never replace a valid result with stale data.
class LocalReviewBatchConcurrencyTest < Minitest::Test
  COMMAND = LocalReviewCodexTest::COMMAND
  include LocalReviewBatchFixture

  def test_concurrent_completion_preserves_both_peers_and_stable_round_numbers
    in_loop do |head|
      workers = start_batch(head, %w[openai/codex anthropic/claude])
      second = release_and_finish(workers.last, 'anthropic/claude')
      first = release_and_finish(workers.first, 'openai/codex')
      assert_completed_order([second, first], %w[anthropic/claude openai/codex])
      %w[openai/codex anthropic/claude].each do |id|
        refute_includes File.read(trace(id)), 'PRIOR ROUNDS:'
      end
    end
  end

  def test_concurrent_duplicate_reviewer_cannot_overwrite_the_successful_peer
    in_loop do |head|
      workers = Array.new(2) { delayed_review(head, 'openai/codex') }
      wait_ready('openai/codex', 'openai/codex')
      File.write(release('openai/codex'), '')
      results = workers.map { |worker| finish(worker, successful: nil) }
      assert_duplicate_result(results)
    end
  end

  def test_late_result_cannot_reopen_an_earlier_batch
    in_loop do |head|
      batch_review(head, 'anthropic/claude')
      worker = delayed_review(head, 'openai/codex')
      wait_ready('openai/codex')
      newer = fix_commit
      batch_review(newer, 'anthropic/claude')
      result = release_and_finish(worker, 'openai/codex', successful: false)
      assert_includes result.fetch('reason'), 'already reviewed'
      assert_ledger_rounds([head, newer])
    end
  end

  def test_moved_checkout_head_rejects_completion_without_changing_the_ledger
    in_loop do |head|
      worker = delayed_review(head, 'openai/codex')
      wait_ready('openai/codex')
      fix_commit
      result = release_and_finish(worker, 'openai/codex', successful: false)
      assert_includes result.fetch('reason'), 'Checkout HEAD'
      refute_path_exists @ledger
    end
  end

  def test_replaced_ledger_is_rejected_without_overwriting_its_contents
    in_loop do |head|
      batch_review(head, 'anthropic/claude')
      worker = delayed_review(head, 'openai/codex')
      wait_ready('openai/codex')
      replacement = JSON.generate('rounds' => [])
      File.write(@ledger, replacement)
      result = release_and_finish(worker, 'openai/codex', successful: false)
      assert_includes result.fetch('reason'), 'changed or was replaced'
      assert_equal replacement, File.read(@ledger)
    end
  end
end
