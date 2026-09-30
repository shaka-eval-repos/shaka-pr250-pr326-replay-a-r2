# frozen_string_literal: true

require_relative 'reviewer_command_test'

# Reuses the repository fixture without inheriting and repeating its tests.
class ReviewerCountCommandTest < Minitest::Test
  include ReviewerCommandFixture

  COMMAND = File.expand_path('../skills/shaka/scripts/shaka', __dir__)
  def test_count_override_and_trusted_configured_default
    with_repository do |root|
      configure_count(root, 2)
      commit_repository(root)
      configure_count(root, 1)

      result = reviewer(root, '--ref', 'HEAD', '--implementer', 'anthropic/claude')
      assert_equal %w[openai/codex anthropic/claude], result.fetch('reviewers')
      override = reviewer(root, '--ref', 'HEAD', '--implementer', 'anthropic/claude', '--count', '3')
      assert_equal %w[openai/codex anthropic/claude xai/grok], override.fetch('reviewers')
    end
  end

  def test_rejects_invalid_count_flags
    with_repository do |root|
      %w[0 -1 1.5 nope].each do |count|
        _, error, status = Open3.capture3(COMMAND, 'reviewer', '--root', root,
                                          '--implementer', 'openai/codex', '--count', count)
        refute_predicate status, :success?
        assert_includes error, '--count must be a positive integer'
      end
    end
  end

  private

  def configure_count(root, count)
    path = File.join(root, '.agents/agent-workflow.yml')
    settings = YAML.safe_load_file(path)
    settings['review']['local_review_count'] = count
    File.write(path, YAML.dump(settings))
  end
end
