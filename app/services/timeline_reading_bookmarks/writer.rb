# frozen_string_literal: true

module TimelineReadingBookmarks
  class Writer
    def initialize(user)
      @user = user
    end

    def create(raw)
      bookmark = nil
      @user.with_lock do
        attributes = Contract.build(raw)
        Access.ensure!(@user.account, attributes[:source], attributes[:context])
        bookmark = @user.timeline_reading_bookmarks.create!(attributes)
      end
      Outcome.ok(bookmark)
    rescue Reject => e
      Outcome.fail(e.code, e.status)
    rescue ActiveRecord::RecordInvalid => e
      Outcome.fail(failure_code(e.record), 422)
    rescue ActiveRecord::RecordNotUnique
      Outcome.fail('duplicate_name', 422)
    end

    def update(id, raw)
      bookmark = nil
      @user.with_lock do
        bookmark = @user.timeline_reading_bookmarks.lock.find(id)
        attributes = Contract.build(raw, existing: bookmark)
        if source_changed?(bookmark, attributes)
          Access.ensure!(@user.account, attributes[:source], attributes[:context])
        end
        bookmark.update!(attributes)
      end
      Outcome.ok(bookmark)
    rescue Reject => e
      Outcome.fail(e.code, e.status)
    rescue ActiveRecord::RecordInvalid => e
      Outcome.fail(failure_code(e.record), 422)
    rescue ActiveRecord::RecordNotUnique
      Outcome.fail('duplicate_name', 422)
    rescue ActiveRecord::StaleObjectError
      Outcome.fail('conflict', 409)
    end

    private

    def source_changed?(bookmark, attributes)
      bookmark.source != attributes[:source] || Contract.stringify(bookmark.context) != Contract.stringify(attributes[:context])
    end

    def failure_code(record)
      return 'limit' if record.errors[:base].include?('limit')
      return 'duplicate_name' if record.errors.details[:name].any? { |detail| detail[:error] == :taken }
      return 'invalid_name' if record.errors[:name].present?
      return 'invalid_context' if record.errors[:context].present?

      'invalid_anchor'
    end
  end
end
