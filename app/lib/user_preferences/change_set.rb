# frozen_string_literal: true

class UserPreferences::ChangeSet
  Operation = Struct.new(:key, :action, :value, :insert, keyword_init: true)

  attr_reader :before, :after, :changed_keys, :unchanged_keys, :writes

  def self.build(stored, request)
    change_set = new
    request.updates.each do |key, value|
      change_set.add_update(key, value, stored.fetch(key))
    end
    request.resets.each do |key|
      change_set.add_reset(key, stored.fetch(key))
    end
    change_set.freeze_members
    change_set
  end

  def initialize
    @before = {}
    @after = {}
    @changed_keys = []
    @unchanged_keys = []
    @writes = []
  end

  def add_update(key, value, stored)
    remember(key, stored)
    if stored[:state] != :absent && stored[:configured] == value
      @unchanged_keys << key
      @after[key] = snapshot(stored[:state], stored[:configured])
      return
    end

    @changed_keys << key
    @writes << Operation.new(key: key, action: :set, value: value, insert: stored[:state] == :absent)
    @after[key] = snapshot(:present, value)
  end

  def add_reset(key, stored)
    remember(key, stored)
    if stored[:state] == :absent
      @unchanged_keys << key
      @after[key] = snapshot(:absent, nil)
      return
    end

    @changed_keys << key
    @writes << Operation.new(key: key, action: :delete, value: nil)
    @after[key] = snapshot(:absent, nil)
  end

  def freeze_members
    @before.freeze
    @after.freeze
    @changed_keys.freeze
    @unchanged_keys.freeze
    @writes.freeze
  end

  private

  def remember(key, stored)
    @before[key] = snapshot(stored[:state], stored[:configured])
  end

  def snapshot(state, configured)
    { state: state, configured: copy_value(configured) }.freeze
  end

  def copy_value(value)
    value.is_a?(String) ? value.dup.freeze : value
  end
end
