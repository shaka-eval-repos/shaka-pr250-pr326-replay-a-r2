# frozen_string_literal: true

require_relative 'test_helper'
require 'fileutils'
require 'json'
require 'yaml'

# The command the workflow invokes, and the trusted-ref path that keeps a candidate branch from
# nominating its own reviewer.
class ReviewerCommandTest < Minitest::Test
  COMMAND = File.expand_path('../skills/shaka/scripts/shaka', __dir__)

  def test_selects_a_reviewer_from_the_seam
    with_repository do |root|
      result = reviewer(root, '--implementer', 'anthropic/claude')

      assert_equal 'different_provider', result.fetch('outcome')
      assert_equal 'openai/codex', result.fetch('reviewer')
    end
  end

  def test_skips_an_unavailable_reviewer
    with_repository do |root|
      result = reviewer(root, '--implementer', 'anthropic/claude',
                        '--unavailable', 'openai/codex')

      assert_equal 'xai/grok', result.fetch('reviewer')
    end
  end

  # A candidate that rewrites review.local_review_agents must not be able to nominate its own family.
  def test_reads_the_reviewer_list_from_the_trusted_ref
    with_repository do |root|
      commit_repository(root)
      rewrite_reviewers(root, [{ 'provider' => 'anthropic', 'model_family' => 'claude' }])

      candidate = reviewer(root, '--implementer', 'anthropic/claude')
      trusted = reviewer(root, '--ref', 'HEAD', '--implementer', 'anthropic/claude')

      assert_equal 'same_provider', candidate.fetch('outcome')
      assert_equal 'openai/codex', trusted.fetch('reviewer')
    end
  end

  def test_validates_optional_command_migration_in_the_candidate_checkout
    { 'validate-local' => '.agents/bin/validate-local does not exist',
      'validate_local' => '.agents/bin/validate_local requires the standard entry point' }.each do |name, expected|
      with_repository do |root|
        write_command(root, name)
        commit_repository(root)
        FileUtils.rm(File.join(root, '.agents/bin/validate-local')) if name == 'validate-local'
        assert_reviewer_rejects(root, expected)
      end
    end
  end

  def test_requires_at_least_one_implementer
    with_repository do |root|
      _, error, status = Open3.capture3(self.class::COMMAND, 'reviewer', '--root', root)

      refute_predicate status, :success?
      assert_includes error, '--implementer is required'
    end
  end

  def test_rejects_an_identity_without_a_model_family
    with_repository do |root|
      _, error, status = Open3.capture3(self.class::COMMAND, 'reviewer', '--root', root,
                                        '--implementer', 'anthropic')

      refute_predicate status, :success?
      assert_includes error, 'PROVIDER/MODEL_FAMILY'
    end
  end
end

# Shared repository setup for single and batch selection commands.
module ReviewerCommandFixture
  private

  def assert_reviewer_rejects(root, expected)
    _, error, status = Open3.capture3(self.class::COMMAND, 'reviewer', '--root', root, '--ref', 'HEAD',
                                      '--implementer', 'anthropic/claude')
    assert_includes error, expected, "expected reviewer failure, got status #{status.exitstatus}"
  end

  def reviewer(root, *)
    output, error, status = Open3.capture3(self.class::COMMAND, 'reviewer', '--root', root, *)
    raise error unless status.success?

    JSON.parse(output)
  end

  def rewrite_reviewers(root, reviewers)
    path = File.join(root, '.agents/agent-workflow.yml')
    config = YAML.safe_load_file(path)
    config['review']['local_review_agents'] = reviewers
    File.write(path, YAML.dump(config))
  end

  def with_repository
    Dir.mktmpdir('shaka-reviewer') do |root|
      FileUtils.mkdir_p(File.join(root, '.agents/bin'))
      %w[setup validate test].each { |name| write_command(root, name) }
      File.write(File.join(root, '.agents/agent-workflow.yml'), YAML.dump(config))
      yield root
    end
  end

  def write_command(root, name)
    path = File.join(root, '.agents/bin', name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
  end

  def config
    { 'version' => 1, 'base_branch' => 'main',
      'review' => { 'required' => 'meaningful_changes', 'ci_review_jobs' => ['claude-review'],
                    'local_review_agents' => [{ 'provider' => 'anthropic', 'model_family' => 'claude' },
                                              { 'provider' => 'openai', 'model_family' => 'codex' },
                                              { 'provider' => 'xai', 'model_family' => 'grok' }] },
      'merge' => { 'preference' => 'ask' } }
  end

  def commit_repository(root)
    git!(root, 'init')
    git!(root, 'add', '.')
    git!(root, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'trusted')
  end

  def git!(root, *)
    output, status = Open3.capture2e('git', '-C', root, *)
    raise output unless status.success?
  end
end

ReviewerCommandTest.include(ReviewerCommandFixture)
