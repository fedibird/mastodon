Fabricator(:moderation_action) do
  subject      { Fabricate(:moderation_subject) }
  action_type  :suspend
  performed_at { Time.now.utc }
end
