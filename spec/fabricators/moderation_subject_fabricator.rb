Fabricator(:moderation_subject) do
  account
  origin        :local
  first_seen_at { Time.now.utc }
  last_seen_at  { Time.now.utc }
end
