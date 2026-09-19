# frozen_string_literal: true

namespace :hashtag_unification do
  # Read-only: no application/database records are created, updated, or deleted.
  # The collision analyzer uses local temporary files to keep memory bounded.
  #
  # Examples:
  #   bundle exec rake hashtag_unification:follow_tag_analysis
  #   SAMPLE_LIMIT=50 bundle exec rake hashtag_unification:follow_tag_analysis
  #
  #   bundle exec rake hashtag_unification:tag_collision_analysis
  #   MANIFEST=/tmp/tag-collisions.csv bundle exec rake hashtag_unification:tag_collision_analysis
  #   BUCKETS=128 BATCH_SIZE=20000 TOP=50 bundle exec rake hashtag_unification:tag_collision_analysis

  desc 'Print read-only FollowTag migration analysis as JSON'
  task follow_tag_analysis: :environment do
    result = HashtagUnification::FollowTagAnalyzer.new(
      sample_limit: ENV.fetch('SAMPLE_LIMIT', HashtagUnification::FollowTagAnalyzer::DEFAULT_SAMPLE_LIMIT)
    ).call

    puts JSON.pretty_generate(result)
  end

  desc 'Print read-only Tag normalization/collision analysis as JSON'
  task tag_collision_analysis: :environment do
    result = HashtagUnification::TagCollisionAnalyzer.new(
      manifest_path: ENV['MANIFEST'],
      bucket_count: ENV.fetch('BUCKETS', HashtagUnification::TagCollisionAnalyzer::DEFAULT_BUCKET_COUNT),
      batch_size: ENV.fetch('BATCH_SIZE', HashtagUnification::TagCollisionAnalyzer::DEFAULT_BATCH_SIZE),
      top_limit: ENV.fetch('TOP', HashtagUnification::TagCollisionAnalyzer::DEFAULT_TOP_LIMIT)
    ).call

    puts JSON.pretty_generate(result)
  end
end
