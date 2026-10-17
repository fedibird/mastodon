# frozen_string_literal: true

module TimelineSeek
  # Versioned, serializable seek result. Invisible posts do not get an anchor
  # id: callers already know the id they sent, and a hidden row must not gain
  # a display target.
  class Result
    VERSION = 1

    attr_reader :version, :outcome, :capability, :precision, :anchor_id, :display_row_id, :limitations, :reason

    def initialize(**attrs)
      @version = attrs.fetch(:version, VERSION)
      @outcome = attrs.fetch(:outcome)
      @capability = attrs.fetch(:capability)
      @precision = attrs[:precision]
      @anchor_id = attrs[:anchor_id]&.to_s
      @display_row_id = attrs[:display_row_id]&.to_s
      @limitations = Array(attrs[:limitations])
      @reason = attrs[:reason]
    end

    def to_h
      body = {
        version: version,
        outcome: outcome,
        capability: capability,
        limitations: limitations,
      }
      body[:precision] = precision if precision
      body[:anchor_id] = anchor_id if anchor_id
      body[:display_row_id] = display_row_id if display_row_id
      body[:reason] = reason if reason
      body
    end

    class << self
      def resolved(anchor_id, capability:, precision: 'exact', limitations: [], reason: nil)
        text = anchor_id.to_s
        new(outcome: 'resolved', capability: capability, precision: precision, anchor_id: text, display_row_id: text, limitations: limitations, reason: reason)
      end

      def not_in_source(capability:, limitations: [], reason: nil)
        new(outcome: 'not_in_source', capability: capability, limitations: limitations, reason: reason)
      end

      def not_visible(capability:, limitations: [], reason: nil)
        new(outcome: 'not_visible', capability: capability, limitations: limitations, reason: reason)
      end

      def not_found(capability:, limitations: [], reason: nil)
        new(outcome: 'not_found', capability: capability, limitations: limitations, reason: reason)
      end

      def unavailable(reason, capability:, limitations: [])
        new(outcome: 'unavailable', capability: capability, limitations: limitations, reason: reason)
      end

      def unsupported(reason, capability: 'unsupported')
        new(outcome: 'unsupported', capability: capability, limitations: [], reason: reason)
      end
    end
  end
end
