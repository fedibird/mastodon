# frozen_string_literal: true

module TimelineSeek
  # Batch membership payload. Confirmed members are ids only. Text, accounts,
  # and search queries are never copied onto the result. A halted outcome
  # (unsupported / unavailable) omits per-id rows so two different id lists
  # cannot be told apart.
  class MembershipResult
    VERSION = 1

    Row = Struct.new(:id, :outcome, :reason, keyword_init: true) do
      def to_h
        body = {}
        body[:id] = id if id
        body[:outcome] = outcome
        body[:reason] = reason if reason
        body
      end
    end

    attr_reader :source, :outcome, :capability, :reason, :limitations, :results

    def initialize(**attrs)
      @source = attrs[:source].to_s
      @outcome = attrs.fetch(:outcome)
      @capability = attrs.fetch(:capability)
      @reason = attrs[:reason]
      @limitations = Array(attrs[:limitations])
      @results = attrs[:results]
    end

    def to_h
      body = {
        version: VERSION,
        source: source,
        scope: 'batch',
        outcome: outcome,
        capability: capability,
        limitations: limitations,
        checked: results ? results.size : 0,
        limits: TimelineSeek::Membership.limits,
      }
      body[:reason] = reason if reason
      if results
        body[:results] = results.map(&:to_h)
        body[:members] = member_ids
      end
      body
    end

    def self.halt(source:, outcome:, capability:, reason:, limitations: [])
      new(source: source, outcome: outcome, capability: capability, reason: reason, limitations: limitations, results: nil)
    end

    def self.classified(source:, outcome:, capability:, limitations:, results:)
      new(source: source, outcome: outcome, capability: capability, limitations: limitations, results: results)
    end

    private

    def member_ids
      results.select { |row| row.outcome == 'member' }.map(&:id).sort { |left, right| right.to_i <=> left.to_i }
    end
  end
end
