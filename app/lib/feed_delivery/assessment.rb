# frozen_string_literal: true

module FeedDelivery
  # Shared filter pass for FeedManager.filter? and FeedInsertWorker.
  #
  # List insertion reuses this decision only inside the same worker call. A
  # direct push_to_list, or a decision for a different status, still runs
  # filter_from_list?.
  module Assessment
    def assess(timeline_type, status, receiver, delivery: nil)
      case timeline_type
      when :home
        assess_home(status, receiver, delivery)
      when :status_notifications
        assess_status_notifications(status, receiver)
      when :list
        assess_list(status, receiver, delivery)
      when :mentions
        issue(filtered: filter_from_mentions?(status, receiver.id))
      when :status_references
        issue(filtered: filter_from_status_references?(status, receiver.id))
      else
        issue(filtered: false)
      end
    end

    def reject_list_insert?(list, status, decision)
      if FeedDelivery.enforce? && trusted_list_reuse?(decision, list, status)
        Metrics.record('list|result=reuse')
        return false
      end

      filtered = filter_from_list?(status, list, build_crutches(list.account_id, [status], list))
      note_crutches! if FeedDelivery.observe?
      compare_list_recheck(decision, list, status, filtered)
      filtered
    end

    private

    def assess_home(status, receiver, delivery)
      crutches = build_crutches(receiver.id, [status])
      FeedDelivery.attach!(crutches, delivery, account_id: receiver.id, list_id: nil)
      issue(filtered: filter_from_home?(status, receiver.id, crutches), timeline_type: :home, status_id: status.id)
    end

    def assess_status_notifications(status, receiver)
      crutches = build_crutches(receiver.id, [status])
      # Displaying boosts and receiving notifications are independent choices.
      crutches[:hiding_reblogs] = {}
      filtered = filter_from_home?(status, receiver.id, crutches, language: status.reblog&.language)
      issue(filtered: filtered, timeline_type: :status_notifications, status_id: status.id)
    end

    def assess_list(status, list, delivery)
      crutches = build_crutches(list.account_id, [status], list)
      note_crutches!
      FeedDelivery.attach!(crutches, delivery, account_id: list.account_id, list_id: list.id)
      list_filtered = filter_from_list?(status, list, crutches)
      filtered = list_filtered || filter_from_home?(status, list.account_id, crutches, list)
      issue(
        filtered: filtered,
        list_admitted: !list_filtered,
        timeline_type: :list,
        status_id: status.id,
        list_id: list.id
      )
    end

    def issue(attrs)
      FeedDelivery.issue_decision(attrs)
    end

    def trusted_list_reuse?(decision, list, status)
      decision.is_a?(InsertDecision) && decision.reuse_for?(list, status)
    end

    def note_crutches!
      Metrics.record('crutches|event=build') if FeedDelivery.observe?
    end

    def compare_list_recheck(decision, list, status, filtered)
      return unless FeedDelivery.shadow?
      return unless decision.is_a?(InsertDecision) && decision.comparable_list?(list, status)

      Metrics.record(decision.list_admitted? == !filtered ? 'list|result=agree' : 'list|result=disagree')
    end
  end
end
