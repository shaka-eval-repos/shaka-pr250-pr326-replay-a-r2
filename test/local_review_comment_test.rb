# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'tempfile'
require 'shaka/local_review'
require 'shaka/merge_review_evidence'

# Builds review rounds whose reports close with a real attestation.
module LocalReviewCommentFixture
  HEAD = 'a' * 40
  EARLIER = 'b' * 40
  TRUSTED = 'c' * 40
  NIT = { 'id' => 'F1', 'summary' => 'Missing test', 'class' => 'nit', 'disposition' => 'documented' }.freeze

  private

  def report(head = HEAD, body: "1. [P2] Missing test.\n", reviewer: 'openai/codex', findings: 1)
    file = Tempfile.create(['report-', '.md'])
    file.write("#{body}\nREVIEWED #{head} BY #{reviewer} EFFORT UNKNOWN FINDINGS #{findings}\n")
    file.close
    (@reports ||= []) << file.path
    file.path
  end

  def round(head = HEAD, **changes)
    { 'head' => head, 'reviewer' => 'openai/codex', 'report' => report(head), 'model' => 'gpt-5.5',
      'prompt_source' => 'Shaka default', 'criteria_ref' => TRUSTED, 'tokens' => '41,200',
      'findings' => [NIT] }.merge(changes.transform_keys(&:to_s))
  end

  def render(content) = Shaka::LocalReviewComment.render(content)

  def teardown
    Array(@reports).each { |path| FileUtils.rm_f(path) }
  end
end

class LocalReviewCommentTest < Minitest::Test
  include LocalReviewCommentFixture

  def test_opens_with_a_title_and_a_summary_row_for_the_round
    body = render('rounds' => [round])

    assert body.start_with?("# Local Adversarial Review\n\n| Round | Commit | Reviewer | Model |")
    assert_includes body, '| 1 | `aaaaaaa` | openai/codex | gpt-5.5 | UNKNOWN | ' \
                          'Shaka default · criteria `ccccccc` | 1 (0 fixed, 1 documented) | 41,200 | UNKNOWN |'
  end

  def test_collapses_each_report_and_closes_with_the_last_attestation
    body = render('rounds' => [round(EARLIER), round])

    assert_equal 2, body.scan("<details>\n<summary>Round ").size
    assert_includes body, "<summary>Round 1 · bbbbbbb · openai/codex · effort UNKNOWN · 1 finding</summary>\n\n1. [P2]"
    assert body.end_with?("</details>\n\nREVIEWED #{HEAD} BY openai/codex EFFORT UNKNOWN FINDINGS 1\n")
  end

  # Break caught: a comment whose last line is not the pushed head's attestation silently fails merge.
  def test_merge_accepts_the_published_comment_as_evidence_for_the_last_round
    marked = "<!-- shaka:reply:#{Shaka::LocalReviewComment::KEY} -->\n#{render('rounds' => [round(EARLIER), round])}"
    github = Struct.new(:issue_comments) { def viewer_login = 'agent' }
    comment = { 'user' => { 'login' => 'agent' }, 'body' => marked, 'html_url' => 'https://example.test/c/1' }

    result = Shaka::MergeReviewEvidence.new(github.new([comment]), required: 'meaningful_changes').call(HEAD)

    assert_equal %w[current_head openai/codex], result.values_at('basis', 'reviewer')
  end

  # Break caught: a supplied `\|` escaped only its pipe and split the row into an extra column.
  def test_keeps_a_supplied_backslash_and_pipe_inside_one_cell
    body = render('rounds' => [round(model: 'a\\|b')])

    assert_includes body, '| a\\\\\\|b |'
  end

  def test_names_missing_criteria_and_a_configured_prompt
    body = render('rounds' => [round(criteria_ref: nil, prompt_source: 'review.prompt_file .agents/p.md')])

    assert_includes body, '| review.prompt_file .agents/p.md · criteria not supplied |'
  end

  def test_explains_a_fallback_with_each_attempt_and_the_setup_guide
    attempts = [{ 'reviewer' => 'xai/grok', 'failure_stage' => 'executable_missing',
                  'reason' => 'grok is not on PATH' }]
    body = render('rounds' => [round], 'fallback' => { 'outcome' => 'same_provider', 'attempts' => attempts })

    assert_includes body, 'used `same_provider`. [Add a second reviewer](https://github.com/shakacode/shaka/' \
                          'blob/main/docs/settings.md#add-a-second-reviewer)'
    assert_includes body, '- `xai/grok`: `executable_missing`: grok is not on PATH'
  end

  # Break caught: a setup failure's reason published a workstation path on a public PR.
  def test_redacts_local_paths_from_fallback_reasons
    reason = 'No such file or directory @ rb_sysopen - /Users/alice/Client Acquisition/notes.md'
    attempts = [{ 'reviewer' => 'openai/codex', 'failure_stage' => 'setup_failure', 'reason' => reason }]
    body = render('rounds' => [round], 'fallback' => { 'outcome' => 'same_provider', 'attempts' => attempts })

    assert_includes body, 'rb_sysopen - [path]'
    refute_match(/alice|Acquisition|notes/, body)
  end

  def test_a_different_provider_review_shows_no_fallback_notice
    body = render('rounds' => [round], 'fallback' => { 'outcome' => 'different_provider' })

    refute_includes body, 'Reviewer fallback'
  end

  def test_refuses_a_report_that_does_not_attest_its_round
    error = assert_raises(Shaka::Error) { render('rounds' => [round(report: report(EARLIER))]) }

    assert_includes error.message, "does not close with REVIEWED #{HEAD}"
  end

  # Break caught: merge parses the attested reviewer and ignores a comment it cannot parse.
  def test_refuses_a_reviewer_merge_cannot_parse
    malformed = report(reviewer: 'openai-codex')

    assert_raises(Shaka::Error) { render('rounds' => [round(reviewer: 'openai-codex', report: malformed)]) }
  end

  # Break caught: with no other provider configured, selection falls back without trying one.
  def test_explains_a_fallback_that_tried_no_other_reviewer
    body = render('rounds' => [round], 'fallback' => { 'outcome' => 'same_model', 'attempts' => [] })

    assert_includes body, 'used `same_model`.'
    refute_includes body, 'Tried:'
  end
end

# Publishes the rendered comment under one stable key.
class LocalReviewPublishTest < Minitest::Test
  include LocalReviewCommentFixture

  ATTESTATION = "REVIEWED #{HEAD} BY openai/codex EFFORT UNKNOWN FINDINGS 1".freeze
  # GitHub's markdown API output for a well-formed one-round comment, trimmed to what the check reads.
  SUMMARY = '<summary>Round 1 · aaaaaaa · openai/codex · effort UNKNOWN · 1 finding</summary>'
  RENDERED = "<h1>Local Adversarial Review</h1>\n<details>\n#{SUMMARY}\n<p>ok</p>\n" \
             "<p>#{ATTESTATION}</p>\n</details>\n<p>#{ATTESTATION}</p>".freeze
  # What GitHub returned when a report opened a four-backtick fence and closed it with three.
  SWALLOWED = "<details>\n<summary>Round 1</summary>\n<pre><code>code\n```\n\n#{ATTESTATION}\n\n" \
              "&lt;/details&gt;\n\n#{ATTESTATION}\n</code></pre></details>".freeze

  # What GitHub returned when round 1's report opened a fence that round 2's report closed, then
  # supplied a balanced replacement disclosure: tag counts and the last line both still look right.
  CROSSED = "<details>\n<summary>Round 1 · bbbbbbb · openai/codex · effort UNKNOWN · 1 finding</summary>\n" \
            "<pre><code>\n&lt;/details&gt;\n\n&lt;details&gt;\n&lt;summary&gt;Round 2 · aaaaaaa&lt;/summary&gt;\n" \
            "</code></pre>\n</details>\n<details>\n<summary>Fake</summary>\n<p>x</p>\n</details>\n" \
            "<p>#{ATTESTATION}</p>".freeze

  # Records the reply instead of calling GitHub, and renders Markdown as told.
  class FakeGitHub
    attr_reader :replies

    def initialize(html = RENDERED, missing: [])
      @html = html
      @missing = missing
      @replies = []
    end

    def markdown(_body) = @html

    def api(path)
      raise Shaka::Error.new('Not Found', http_status: 404) if @missing.any? { |sha| path.end_with?(sha) }
      raise Shaka::Error.new('Validation failed', http_status: 422) if @outage

      {}
    end

    attr_writer :outage

    def reply(body:, key:)
      @replies << [key, body]
      { 'id' => 1 }
    end
  end

  def publish(github, content)
    Tempfile.create(['content-', '.json']) do |file|
      file.write(JSON.generate(content))
      file.close
      out, err = capture_io do
        @status = Shaka::LocalReview.run(['publish', 'o/r', '7', '--content-file', file.path], github:)
      end
      [@status, out, err]
    end
  end

  def test_publishes_under_the_local_review_key
    github = FakeGitHub.new

    status, = publish(github, 'rounds' => [round])

    assert_equal 0, status
    assert_equal ['local-adversarial-review'], github.replies.map(&:first)
    assert github.replies.first.last.start_with?('# Local Adversarial Review')
    assert_includes github.replies.first.last, "| 1 | [`aaaaaaa`](https://github.com/o/r/commit/#{HEAD}) |"
  end

  # Break caught: a round reviewed before a rebase linked a commit GitHub never received.
  def test_names_a_commit_github_does_not_have_without_linking_it
    content = { 'rounds' => [round(EARLIER, report: report(EARLIER)), round] }
    body = Shaka::LocalReviewComment.new(content, repository: 'o/r', published: ->(sha) { sha != EARLIER }).render

    assert_includes body, '| 1 | `bbbbbbb` (not on GitHub) |'
    assert_includes body, "| 2 | [`aaaaaaa`](https://github.com/o/r/commit/#{HEAD}) |"
  end

  # Break caught: a transient API failure labeled a pushed commit as missing from GitHub.
  def test_a_failed_commit_lookup_stops_publication
    github = FakeGitHub.new
    github.outage = true

    status, = publish(github, 'rounds' => [round])

    assert_equal 1, status
    assert_empty github.replies
  end

  # Break caught: a report's unclosed fence hid the closing details and the attestation, yet merge
  # would still have read the raw last line as evidence.
  def test_refuses_when_github_would_swallow_the_attestation
    [SWALLOWED, RENDERED.sub('</details>', ''), RENDERED.sub('<details>', '<details><details>')].each do |html|
      github = FakeGitHub.new(html)

      status, _out, err = publish(github, 'rounds' => [round])

      assert_equal 1, status
      assert_empty github.replies
      assert_includes err, 'leaves its markup open'
    end
  end

  # Break caught: a fence spanning two reports replaced the boundary between them with its own tags.
  def test_refuses_when_a_report_replaces_the_next_rounds_disclosure
    github = FakeGitHub.new(CROSSED)

    status, = publish(github, 'rounds' => [round(EARLIER), round])

    assert_equal 1, status
    assert_empty github.replies
  end
end

# Renders what became of each finding, round by round.
class LocalReviewDispositionTest < Minitest::Test
  include LocalReviewCommentFixture

  FIX = 'd' * 40

  def finding(id, kind, disposition, **extra)
    { 'id' => id, 'summary' => "#{kind} #{id}", 'class' => kind, 'disposition' => disposition }
      .merge(extra.transform_keys(&:to_s))
  end

  def looped
    first = round(EARLIER, report: report(EARLIER, findings: 2),
                           findings: [finding('F1', 'defect', 'fixed', commit: FIX),
                                      finding('F2', 'nit', 'documented', note: 'naming is out of scope')])
    { 'rounds' => [first, round(report: report(body: "no findings\n", findings: 0), findings: [])] }
  end

  # Break caught: a two-round loop must publish one comment whose last line is round 2's attestation.
  def test_merge_accepts_a_two_round_loop_with_dispositions
    body = Shaka::LocalReviewComment.new(looped, repository: 'o/r').render
    github = Struct.new(:issue_comments) { def viewer_login = 'agent' }
    comment = { 'user' => { 'login' => 'agent' }, 'body' => "<!-- shaka:reply:local-adversarial-review -->\n#{body}",
                'html_url' => 'https://example.test/c/1' }

    result = Shaka::MergeReviewEvidence.new(github.new([comment]), required: 'meaningful_changes').call(HEAD)

    assert_equal %w[current_head openai/codex], result.values_at('basis', 'reviewer')
    assert_looped(body)
  end

  def assert_looped(body)
    assert_equal 2, body.scan("<details>\n<summary>Round ").size
    assert_includes body, '| 2 (1 fixed, 1 documented) |'
    assert_includes body, "- `F1` defect: defect F1 — fixed in [`ddddddd`](https://github.com/o/r/commit/#{FIX})"
    assert_includes body, '- `F2` nit: nit F2 — documented nit — naming is out of scope'
    assert body.end_with?("</details>\n\nREVIEWED #{HEAD} BY openai/codex EFFORT UNKNOWN FINDINGS 0\n")
  end

  def test_flags_a_finding_that_returns_after_its_fix
    content = looped
    content['rounds'][1] = round(findings: [finding('F1', 'defect', 'fixed', commit: 'e' * 40)])
    content['rounds'] << round('e' * 40, report: report('e' * 40, findings: 0), findings: [])

    assert_includes render(content), '· **returned after its fix in `ddddddd`**'
  end

  # Break caught: a round with findings published without saying what became of them.
  def test_refuses_a_round_whose_findings_were_not_recorded
    error = assert_raises(Shaka::Error) { render('rounds' => [round(findings: nil)]) }

    assert_includes error.message, "Round 1's report counts 1 findings; 0 were recorded."
  end

  def test_refuses_a_repeated_finding_id_in_a_round
    content = { 'rounds' => [round(report: report(findings: 2), findings: [NIT, NIT])] }

    assert_includes assert_raises(Shaka::Error) { render(content) }.message, 'id repeats'
  end

  def test_refuses_fixing_a_nit_and_a_fix_without_its_commit
    [finding('F1', 'nit', 'fixed', commit: FIX), finding('F1', 'defect', 'fixed'),
     finding('F1', 'risk', 'documented', commit: FIX)].each do |bad|
      assert_raises(Shaka::Error) { render('rounds' => [round(findings: [bad])]) }
    end
    fixed = round(EARLIER, report: report(EARLIER), findings: [finding('F1', 'risk', 'fixed', commit: FIX)])
    assert_includes render('rounds' => [fixed, round]), 'risk F1 — fixed in `ddddddd`'
  end

  # Break caught: a direct content file claimed a fix in the reviewed commit, or re-reviewed one head.
  def test_refuses_a_fix_in_the_reviewed_commit_and_a_repeated_head
    own = round(EARLIER, report: report(EARLIER), findings: [finding('F1', 'defect', 'fixed', commit: EARLIER)])
    repeated = round(EARLIER, report: report(EARLIER, findings: 0), findings: [])

    assert_includes assert_raises(Shaka::Error) { render('rounds' => [own, round]) }.message, 'commit it reviewed'
    assert_includes assert_raises(Shaka::Error) { render('rounds' => [repeated, repeated]) }.message, 'same commit'
  end

  # Break caught: a fix recorded in the last round was published without any review of it.
  def test_refuses_a_last_round_whose_fixes_no_round_reviewed
    fixed = round(findings: [finding('F1', 'defect', 'fixed', commit: FIX)])

    assert_includes assert_raises(Shaka::Error) { render('rounds' => [fixed]) }.message, 'no later round reviewed'
  end
end

# The lines under the table: cost, why the loop stopped, and what the prompt column means.
class LocalReviewSummaryTest < Minitest::Test
  include LocalReviewCommentFixture

  def test_totals_tokens_and_marks_an_api_equivalent_estimate
    body = render('rounds' => [round(EARLIER, report: report(EARLIER), estimate: '$0.17'),
                               round(estimate: '$0.20', tokens: '1,000')])

    assert_includes body, '| 41,200 | $0.17 est. |'
    assert_includes body, '**Total:** 2 rounds · 42,200 tokens · $0.37 API-equivalent estimate'
    partial = render('rounds' => [round(estimate: '$0.17 (partial)')])
    assert_includes partial, '$0.17 API-equivalent estimate (partial)'
  end

  def test_an_unpriced_round_leaves_the_total_cost_unknown
    assert_includes render('rounds' => [round]), '**Total:** 1 round · 41,200 tokens · cost UNKNOWN'
  end

  def test_says_why_the_loop_stopped
    clean = round(report: report(body: "no findings\n", findings: 0), findings: [])

    assert_includes render('rounds' => [clean]), '**Outcome:** the loop ended clean: round 1 found nothing.'
    assert_includes render('rounds' => [round]),
                    '**Outcome:** the loop ended with nothing left to fix. Round 1\'s findings are documented ' \
                    'nits or risks (1 nit).'
  end

  # Break caught: a documented defect, in the last round or an earlier one, read as a clean finish.
  def test_names_an_unfixed_defect_from_any_round
    defect = { 'id' => 'F6', 'summary' => 'No history check', 'class' => 'defect', 'disposition' => 'documented' }
    clean = round(report: report(body: "no findings\n", findings: 0), findings: [])
    earlier = round(EARLIER, report: report(EARLIER), findings: [defect])

    risk = round(report: report, findings: [defect.merge('class' => 'risk')])
    [[round(findings: [defect])], [earlier, clean], [earlier, risk]].each do |rounds|
      assert_includes render('rounds' => rounds), '**Outcome:** the loop stopped with 1 unfixed defect left for'
    end
  end

  def test_defines_the_prompt_column_and_links_the_criteria
    body = Shaka::LocalReviewComment.new({ 'rounds' => [round] }, repository: 'o/r').render

    assert_includes body, "criteria [`ccccccc`](https://github.com/o/r/tree/#{TRUSTED})"
    assert_includes body, '**Prompt:** `Shaka default` is Shaka\'s [review instructions]'
  end
end

# Batch publication must keep every peer's findings and disposition visible.
class LocalReviewBatchCommentTest < Minitest::Test
  include LocalReviewCommentFixture

  def test_publishes_same_head_peers_and_keeps_earlier_evidence
    earlier = round(EARLIER)
    peer = round(reviewer: 'anthropic/claude', report: report(reviewer: 'anthropic/claude'), findings: [NIT])
    clean = round(report: report(findings: 0), findings: [])
    body = render('rounds' => [earlier, peer, clean])

    assert_equal 3, body.scan('<details>').size
    assert_includes body, '| 2 | `aaaaaaa` | anthropic/claude |'
    assert_includes body, "latest batch's findings are documented nits or risks (1 nit)"
    assert_equal 2, body.scan('— documented nit').size
    assert body.end_with?("REVIEWED #{HEAD} BY openai/codex EFFORT UNKNOWN FINDINGS 0\n")
  end

  def test_clean_peer_does_not_hide_a_defect_or_a_fix_in_the_latest_batch
    defect = { 'id' => 'F1', 'summary' => 'Broken behavior', 'class' => 'defect', 'disposition' => 'documented' }
    peer = round(reviewer: 'anthropic/claude', report: report(reviewer: 'anthropic/claude'), findings: [defect])
    clean = round(report: report(findings: 0), findings: [])
    assert_includes render('rounds' => [peer, clean]), '1 unfixed defect'
    peer['findings'] = [defect.merge('disposition' => 'fixed', 'commit' => 'd' * 40)]
    error = assert_raises(Shaka::Error) { render('rounds' => [peer, clean]) }
    assert_includes error.message, 'no later round reviewed'
  end

  def test_peer_ids_cannot_erase_one_anothers_defects
    defect = { 'id' => 'F1', 'summary' => 'Broken behavior', 'class' => 'defect', 'disposition' => 'documented' }
    fixed = defect.merge('disposition' => 'fixed', 'commit' => HEAD)
    first = round(EARLIER, findings: [defect])
    peer = round(EARLIER, reviewer: 'anthropic/claude',
                          report: report(EARLIER, reviewer: 'anthropic/claude'), findings: [fixed])
    clean = round(report: report(findings: 0), findings: [])
    assert_includes render('rounds' => [first, peer, clean]), '1 unfixed defect'
  end

  def test_rejects_incomplete_peers_duplicate_identities_and_reopened_batches
    peer = round(reviewer: 'anthropic/claude', report: report(reviewer: 'anthropic/claude'), findings: [])
    assert_raises(Shaka::Error) { render('rounds' => [round, peer]) }
    assert_raises(Shaka::Error) { render('rounds' => [round, round(reviewer: 'OpenAI/Codex')]) }
    peer['findings'] = [NIT]
    error = assert_raises(Shaka::Error) { render('rounds' => [round, round(EARLIER), peer]) }
    assert_includes error.message, 'earlier-head batch reappears'
  end
end
