# frozen_string_literal: true

module ExternalBridge
  module RSS
    # The unsubscribe fence seen from a writer.
    #
    # Unsubscribe (the request) takes the subscription row FOR UPDATE and moves
    # it to `deleting`. A writer that creates or changes a projection, or records
    # an item failure, runs inside guard!: it takes the same row FOR SHARE in its
    # own transaction and refuses to continue when the row is deleting or gone.
    # The two lock modes conflict, so every write either commits before the
    # fence (and the deletion job, which starts after the fence commits, sees
    # it) or starts after it and is refused. The state is read under the lock,
    # not from the model the fetch started with.
    module SubscriptionFence
      # A writer reached a subscription that is being removed. Callers that loop
      # over items stop on it instead of counting the item as a failure.
      class Fenced < ExternalBridge::Error
        def initialize
          super(:subscription_deleting)
        end
      end

      module_function

      def guard!(subscription_or_id)
        id = subscription_or_id.respond_to?(:id) ? subscription_or_id.id : subscription_or_id
        ApplicationRecord.transaction(requires_new: true) do
          state = ExternalSubscription.where(id: id).lock('FOR SHARE').pick(:state)
          raise Fenced if state.nil? || state == ExternalSubscription::DELETING

          yield
        end
      end
    end
  end
end
