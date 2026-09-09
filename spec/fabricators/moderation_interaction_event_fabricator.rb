Fabricator(:moderation_interaction_event) do
  actor_subject  { Fabricate(:moderation_subject) }
  target_subject { Fabricate(:moderation_subject) }
  event_type     :follow
  occurred_at    { Time.now.utc }
  observed_at    { Time.now.utc }
end
