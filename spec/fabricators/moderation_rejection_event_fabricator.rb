Fabricator(:moderation_rejection_event) do
  rejector_subject { Fabricate(:moderation_subject) }
  rejected_subject { Fabricate(:moderation_subject) }
  event_type       :block
  occurred_at      { Time.now.utc }
  observed_at      { Time.now.utc }
end
