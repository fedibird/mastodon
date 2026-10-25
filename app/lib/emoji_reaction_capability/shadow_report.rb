# frozen_string_literal: true

module EmojiReactionCapability
  # Reads the hourly counters written by ShadowRecorder and summarizes them.
  # Read-only; used by `rake emoji_reactions:shadow:report`.
  module ShadowReport
    extend Redisable

    module_function

    # hours: number of UTC hourly buckets, newest first, including the current.
    def collect(hours: 24, now: Time.now.utc)
      keys = Array.new(hours) { |i| ShadowRecorder.key_for(now - i.hours) }

      with_redis do |conn|
        keys.each_with_object(Hash.new(0)) do |key, totals|
          conn.hgetall(key).each { |field, count| totals[field] += count.to_i }
        end
      end
    end

    def summarize(fields)
      summary = {
        ops: Hash.new { |h, k| h[k] = { total: 0, match: 0, diff: 0 } },
        diffs: Hash.new(0),
        nodes: Hash.new(0),
        families: Hash.new(0),
        reachability: Hash.new(0),
        flags: { stale: 0, override: 0, stale_ignored: 0, total: 0 },
        errors: Hash.new(0),
      }

      fields.each do |field, count|
        type, *pairs = field.split('|')
        attrs = pairs.to_h { |pair| pair.split('=', 2) }

        case type
        when 'cmp' then add_comparison(summary, attrs, count)
        when 'snap' then add_snapshot(summary, attrs, count)
        when 'err' then summary[:errors][attrs['op']] += count
        end
      end

      summary
    end

    def add_comparison(summary, attrs, count)
      op = summary[:ops][attrs['op']]
      op[:total] += count
      op[attrs['result'].to_sym] += count if %w(match diff).include?(attrs['result'])
      return unless attrs['result'] == 'diff'

      key = attrs.slice('op', 'kind', 'family', 'node', 'legacy', 'proposed', 'basis')
      key['reason'] = ShadowComparator.reason(op: attrs['op'], legacy: attrs['legacy'], proposed: attrs['proposed'], basis: attrs['basis'])
      summary[:diffs][key] += count
    end

    def add_snapshot(summary, attrs, count)
      summary[:nodes][attrs['node']] += count
      summary[:families][attrs['family']] += count
      summary[:reachability][attrs['reach']] += count
      summary[:flags][:total] += count
      summary[:flags][:stale] += count if attrs['stale'] == '1'
      summary[:flags][:override] += count if attrs['override'] == '1'
      summary[:flags][:stale_ignored] += count if attrs['stale_ignored'] == '1'
    end

    def render(summary)
      lines = ['Emoji reaction resolver shadow report (counts are sampled observations)', '']

      lines << 'Legacy vs proposed, by operation'
      summary[:ops].sort.each do |name, op|
        rate = op[:total].positive? ? format('%.1f%%', op[:match] * 100.0 / op[:total]) : 'n/a'
        lines << format('  %-14s total=%-8d match=%-8d diff=%-8d match_rate=%s', name, op[:total], op[:match], op[:diff], rate)
      end

      lines << '' << 'Differences (op kind family node: legacy -> proposed [basis] reason)'
      summary[:diffs].sort_by { |_key, count| -count }.each do |key, count|
        lines << format('  %-8d %s %s %s %s: %s -> %s [%s] %s', count, *key.values_at('op', 'kind', 'family', 'node', 'legacy', 'proposed', 'basis', 'reason'))
      end

      flags = summary[:flags]
      lines << '' << "Node snapshots read: #{flags[:total]}"
      lines << "  by state:  #{format_counts(summary[:nodes])}"
      lines << "  by family: #{format_counts(summary[:families])}"
      lines << "  by reachability: #{format_counts(summary[:reachability])}"
      lines << "  stale=#{flags[:stale]} admin_override=#{flags[:override]} stale_info_ignored=#{flags[:stale_ignored]}"
      lines << "  errors: #{format_counts(summary[:errors])}" if summary[:errors].any?
      lines.join("\n")
    end

    def format_counts(counts)
      counts.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(' ')
    end
  end
end
