# frozen_string_literal: true

# Writer-only counter. A missing row means revision 0 and is not inserted
# until a change commits. Decorator saves do not move this number.
class UserPreferences::Revision
  def self.current(user_id)
    UserPreferenceRevision.find_by(user_id: user_id)&.revision || 0
  end

  def self.current_for_update(user_id)
    UserPreferenceRevision.lock.find_by(user_id: user_id)&.revision || 0
  end

  def self.advance!(user_id)
    row = UserPreferenceRevision.lock.find_by(user_id: user_id)
    if row
      row.update!(revision: row.revision + 1)
      row.revision
    else
      UserPreferenceRevision.create!(user_id: user_id, revision: 1).revision
    end
  end
end
