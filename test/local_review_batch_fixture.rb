# frozen_string_literal: true

require_relative 'local_review_test'
require 'timeout'
require 'shaka/local_review/ledger'

# Assertions shared by independent completion and disposition tests.
module LocalReviewBatchAssertions
  private

  def assert_prior_batch(id)
    prompt = File.read(trace(id))
    assert_includes prompt, 'Wrong exit code'
    assert_includes prompt, 'Peer concern'
    refute_includes prompt, 'private reasoning'
  end

  def assert_completed_order(results, reviewers)
    assert_equal([1, 2], results.map { |result| result.fetch('round') })
    assert_equal(reviewers, ledger.rounds.map { |round| round.fetch('reviewer') })
  end

  def assert_duplicate_result(results)
    assert_equal %w[completed not_completed], results.map { |result| result.fetch('status') }.sort
    assert_equal 1, ledger.rounds.size
    assert_includes results.find { |result| result['status'] == 'not_completed' }.fetch('reason'), 'already reviewed'
  end
end

# Fake processes and stable record targets shared by batch integration tests.
module LocalReviewBatchFixture
  include LocalReviewFixture
  include LocalReviewLoopSteps
  include LocalReviewBatchAssertions

  def teardown
    Array(@results).each { |result| cleanup_artifacts(result) }
  end

  private

  def ledger = Shaka::LocalReviewLedger.new(@ledger)
  def trace(id) = File.join(@bin, "#{id.tr('/', '-')}.prompt")
  def release(id) = "#{trace(id)}.release"

  def fake_batch(head, id, findings:, delayed: false)
    name = id == 'openai/codex' ? 'codex' : 'claude'
    report = "batch report\nREVIEWED #{head} BY #{id} EFFORT medium FINDINGS #{findings}\n"
    write_executable(@bin, name, batch_script(id, report, delayed))
  end

  def batch_script(id, report, delayed)
    <<~RUBY
      #!/usr/bin/env ruby
      require 'json'
      File.write(#{trace(id).inspect}, STDIN.read)
      File.write(#{trace(id).inspect} + '.' + Process.pid.to_s + '.ready', '')
      sleep 0.01 until File.exist?(#{release(id).inspect}) if #{delayed}
      report = #{report.inspect}
      if File.basename($PROGRAM_NAME) == 'codex'
        File.write(ARGV.fetch(ARGV.index('-o') + 1), report)
      else
        puts JSON.generate(is_error: false, result: report)
      end
    RUBY
  end

  def batch_review(head, id, findings: 0)
    fake_batch(head, id, findings:)
    output, error, status = run_review(@root, @base, head, @bin, reviewer: id, effort: 'medium', ledger: @ledger)
    result = assert_successful_review(output, error, status, head, id)
    (@results ||= []) << result
    result
  end

  def delayed_review(head, id)
    fake_batch(head, id, findings: 0, delayed: true)
    Thread.new do
      run_review(@root, @base, head, @bin, reviewer: id, effort: 'medium', ledger: @ledger, timeout_seconds: 10)
    end
  end

  def wait_ready(*ids)
    Timeout.timeout(5) do
      sleep 0.01 until ids.tally.all? { |id, count| Dir.glob("#{trace(id)}.*.ready").size >= count }
    end
  end

  def finish(worker, successful: true)
    output, error, status = Timeout.timeout(15) { worker.value }
    assert_equal successful, status.success?, error unless successful.nil?
    result = JSON.parse(output)
    (@results ||= []) << result
    result
  end

  def findings_batch(head)
    batch_review(head, 'openai/codex', findings: 1)
    batch_review(head, 'anthropic/claude', findings: 1)
  end

  def start_batch(head, ids)
    workers = ids.map { |id| delayed_review(head, id) }
    wait_ready(*ids)
    workers
  end

  def release_and_finish(worker, id, successful: true)
    File.write(release(id), '')
    finish(worker, successful:)
  end

  def prior_prompt(id)
    File.read(trace(id))[/Findings:.*?--- END PRIOR ROUND DATA/m].sub(/ [0-9a-f]{32}/, '')
  end

  def concurrent_dispositions
    [1, 2].map { |number| Thread.new { disposition(number) } }.each(&:value)
  end

  def finding(number, fix: nil)
    { 'id' => 'F1', 'summary' => number == 1 ? 'Wrong exit code' : 'Peer concern',
      'class' => 'defect', 'disposition' => fix ? 'fixed' : 'documented',
      'note' => 'private reasoning' }.merge(fix ? { 'commit' => fix } : {})
  end

  def disposition(number, fix: nil)
    Tempfile.create(['batch-record-', '.json']) do |file|
      file.write(JSON.generate('findings' => [finding(number, fix:)]))
      file.close
      output, error, status = Open3.capture3(self.class::COMMAND, 'review', 'record', '--ledger', @ledger,
                                             '--round', number.to_s, '--content-file', file.path)
      assert_predicate status, :success?, error
      assert_equal number, JSON.parse(output).fetch('round')
    end
  end
end
