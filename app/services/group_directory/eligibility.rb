# frozen_string_literal: true

# Who may appear in the group directory, and therefore in GroupDirectoryIndex.
#
# The rules match GroupDirectory::Query's public listing: discoverable groups
# that are approved, not suspended, not silenced, and not moved. Remote groups
# also need NodeInfo that does not report PeerTube. A missing NodeInfo row is
# left out; it is not guessed to be PeerTube. Local groups need a confirmed
# approved login, or a ManagedGroup when the group has no login.
#
# Viewer blocks, follows, and search text are not part of eligibility. Those
# stay out of the shared document.
class GroupDirectory::Eligibility
  PEERTUBE = 'peertube'
  KNOWN_SOFTWARE = %w(fedibird lemmy piefed nodebb mbin mitra).freeze
  SOFTWARE_NAME_SQL = "LOWER(BTRIM(COALESCE(nodes.info->>'software_name', '')))"

  class << self
    def scope
      table = Account.arel_table
      remote = table[:domain].in(remote_domains.select(:domain).arel)

      Account.discoverable.groups
             .where(table[:domain].eq(nil).or(remote))
             .includes(:account_stat, :group_languages, :node, :user, :managed_group)
    end

    def remote_domains
      Node.has_nodeinfo.where("#{SOFTWARE_NAME_SQL} <> ?", PEERTUBE)
    end

    def eligible?(account)
      return false if account.nil? || account.destroyed?
      return false unless account.group?
      return false unless account.discoverable == true
      return false if account.suspended? || account.silenced? || account.moved?
      return false unless persisted_stat?(account)
      return false unless approved_for_listing?(account)
      return true if account.local?

      remote_listable?(account)
    end

    # Node refreshes rewrite user counts and other info keys. Only a software
    # name change, a change in whether NodeInfo is present, or a domain change
    # moves a group in or out of the directory.
    def node_directory_inputs_changed?(node)
      return true if node.destroyed?

      changes = node.previous_changes
      return false if (changes.keys & %w(info nodeinfo domain)).empty?

      software_changed?(changes) || nodeinfo_presence_changed?(changes) || changes.key?('domain')
    end

    def nodeinfo_missing?(nodeinfo)
      nodeinfo.nil? || nodeinfo['error'] == 'missing'
    end

    def normalized_software_name(info)
      value = info.is_a?(Hash) ? info['software_name'] : nil
      value.to_s.strip.downcase
    end

    private

    def persisted_stat?(account)
      stat = account.association(:account_stat).target if account.association(:account_stat).loaded?
      return true if stat&.persisted?

      AccountStat.where(account_id: account.id).exists?
    end

    def approved_for_listing?(account)
      return true unless account.local?

      user = account.user
      return true if user&.approved? && user&.confirmed?

      account.managed_group.present?
    end

    def remote_listable?(account)
      node = account.node
      return false if node.nil? || node.missing?

      normalized_software_name(node.info) != PEERTUBE
    end

    def software_changed?(changes)
      return false unless changes.key?('info')

      before_info, after_info = changes['info']
      normalized_software_name(before_info) != normalized_software_name(after_info)
    end

    def nodeinfo_presence_changed?(changes)
      return false unless changes.key?('nodeinfo')

      before_nodeinfo, after_nodeinfo = changes['nodeinfo']
      nodeinfo_missing?(before_nodeinfo) != nodeinfo_missing?(after_nodeinfo)
    end
  end
end
