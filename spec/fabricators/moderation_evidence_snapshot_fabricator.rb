Fabricator(:moderation_evidence_snapshot) do
  subject        { Fabricate(:moderation_subject) }
  window_start   { 30.days.ago }
  window_end     { Time.now.utc }
  schema_version 1
end
