# frozen_string_literal: true

# Per-request or per-job memo of user_preference_revisions.
# Outside RevisionMemo.scope, every lookup reads PostgreSQL and stores nothing.
class UserPreferences::RevisionMemo < ActiveSupport::CurrentAttributes
  attribute :revisions, :depth

  class << self
    def scope
      token = enter!
      yield
    ensure
      leave!(token)
    end

    def revision_for(user_id)
      id = integer_id(user_id)
      return UserPreferences::Revision.current(id) unless scoped?

      store = revisions
      return store[id] if store.key?(id)

      value = UserPreferences::Revision.current(id)
      store[id] = value
      value
    end

    # Called only after a Writer transaction has committed.
    def remember!(user_id, revision)
      return unless scoped?
      raise ArgumentError, 'revision must be an integer' unless revision.is_a?(Integer)

      revisions[integer_id(user_id)] = revision
    end

    private

    def scoped?
      depth.to_i.positive?
    end

    def enter!
      self.depth = depth.to_i + 1
      self.revisions ||= {}
      depth
    end

    def leave!(token)
      return unless depth == token

      if depth <= 1
        reset
      else
        self.depth = depth - 1
      end
    end

    def integer_id(user_id)
      raise ArgumentError, 'user id is required' if user_id.nil?

      user_id.to_i
    end
  end
end
