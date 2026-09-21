# frozen_string_literal: true

require 'digest'

# Privacy-safe labels for default backtest output. Blank keys are
# labelled `unknown` and never hashed into a fake identity.
module FollowImport
  class PacingBacktest
    module Privacy
      module_function

      def destination_label(value)
        label('d', value)
      end

      def origin_label(value)
        label('o', value)
      end

      def label(prefix, value)
        text = value.to_s.strip
        return 'unknown' if text.empty?

        "#{prefix}_#{Digest::SHA256.hexdigest(text)[0, 12]}"
      end
    end
  end
end
