# frozen_string_literal: true

module FeedDelivery
  # In-process result of one filter pass. Sidekiq cannot carry this object.
  # Constructing it outside FeedDelivery.issue_decision raises, so a job
  # argument cannot set validated: true and skip the list check.
  class InsertDecision
    def self.construct(attrs)
      raise ArgumentError, 'insert decisions are internal' unless FeedDelivery.issuing_decision?

      new(attrs)
    end

    def initialize(attrs)
      @filtered = attrs[:filtered] == true
      @list_admitted = attrs[:list_admitted] == true
      @timeline_type = attrs[:timeline_type]
      @status_id = attrs[:status_id]
      @list_id = attrs[:list_id]
      freeze
    end

    def filtered?
      @filtered
    end

    def list_admitted?
      @list_admitted
    end

    def reuse_for?(list, status)
      @timeline_type == :list && list_admitted? && !filtered? && @list_id == list.id && @status_id == status.id
    end

    def comparable_list?(list, status)
      @timeline_type == :list && @list_id == list.id && @status_id == status.id
    end

    private_class_method :new
  end
end
