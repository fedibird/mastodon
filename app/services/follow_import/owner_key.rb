# frozen_string_literal: true

# Opaque fairness identity for the portable Follow Import planner.
#
# The planner compares these keys only. It must not know about
# ModerationSubject, reputation, or account handles. The Fedibird adapter
# derives a key from the local importing account id at the batch-loading
# edge; that numeric id is an implementation input, not the scheduling
# contract.
module FollowImport
  class OwnerKey
    include Comparable

    def self.for_batch(batch)
      from_account_id(batch.for_account&.id)
    end

    def self.from_account_id(account_id)
      return if account_id.nil?

      new("a:#{account_id.to_i}")
    end

    def initialize(value)
      @value = value.to_s
      raise ArgumentError, 'owner key is blank' if @value.blank?
    end

    attr_reader :value

    def to_s
      value
    end

    def <=>(other)
      value <=> other.to_s
    end

    def eql?(other)
      other.is_a?(self.class) && value == other.value
    end
    alias == eql?

    def hash
      value.hash
    end
  end
end
