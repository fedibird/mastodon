# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Server policy for article videos. Read at execution time. Job arguments
      # do not carry a snapshot, so a flip to remote during a download does not
      # keep copying. A flip to hybrid does not backfill videos that were
      # already judged under remote.
      module Policy
        MODES = %w(remote hybrid).freeze
        DEFAULT_MIB = 20
        STORABLE_MIME = %w(video/mp4 video/webm).freeze

        module_function

        def mode
          value = Setting.external_bridge_rss_video_policy.to_s
          MODES.include?(value) ? value : 'remote'
        end

        def hybrid?
          mode == 'hybrid'
        end

        def max_mib
          MediaAttachment::VIDEO_LIMIT / 1.megabyte
        end

        def max_bytes
          mib = Setting.external_bridge_rss_video_max_download_mib.to_i
          mib = DEFAULT_MIB unless (1..max_mib).cover?(mib)
          mib.megabytes
        end

        def storable_mime?(value)
          STORABLE_MIME.include?(value.to_s.split(';').first.to_s.strip.downcase)
        end
      end
    end
  end
end
