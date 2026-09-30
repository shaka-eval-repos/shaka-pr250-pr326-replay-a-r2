# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'repository_fixture'
require 'shaka/repository_config'

class ReviewCountPolicyTest < Minitest::Test
  include RepositoryConfigTestHelpers

  def test_loads_optional_local_review_count
    with_repository('review' => review_policy('local_review_count' => 2)) do |root|
      assert_equal 2, Shaka::RepositoryConfig.load(root:).review.fetch('local_review_count')
    end
  end

  def test_rejects_invalid_local_review_counts
    [0, -1, 1.5, '2', nil, true].each do |count|
      with_repository('review' => review_policy('local_review_count' => count)) do |root|
        error = assert_raises(Shaka::Error) { Shaka::RepositoryConfig.load(root:) }
        assert_includes error.message, 'local_review_count'
      end
    end
  end
end
