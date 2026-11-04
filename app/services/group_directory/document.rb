# frozen_string_literal: true

# Values stored in GroupDirectoryIndex. No private keys, e-mail, or profile
# fields. Language tags are the group's own group_languages rows; NodeInfo
# languages and post languages are not copied.
#
# Search text is capped so the bounded ngram cannot grow with a remote note.
# Names are placed first, so a long note cannot push the name out of the cap.
# plain_note keeps the first NOTE_LIMIT characters only. SQL ILIKE still
# searches the whole accounts.note column, because the directory API does
# not read this index yet. The tail of a longer remote note is absent from
# the index on purpose; do not treat the index as a full-note search.
class GroupDirectory::Document
  NOTE_LIMIT = 2_000
  SEARCH_TEXT_LIMIT = 2_500

  class << self
    def username(account)
      account.username.to_s.downcase
    end

    def acct(account)
      account.acct.to_s.downcase
    end

    # @name@this-server matches a local row, whose domain column is null.
    def local_domain_acct(account)
      return unless account.local?

      "#{username(account)}@#{Rails.configuration.x.local_domain.to_s.downcase}"
    end

    # Empty string marks a local group. A missing field would look like an
    # unfetched remote domain.
    def domain_key(account)
      account.local? ? '' : account.domain.to_s.downcase
    end

    def plain_note(account)
      stripped = ActionController::Base.helpers.strip_tags(account.note.to_s)
      CGI.unescapeHTML(stripped).gsub(/\s+/, ' ').strip.first(NOTE_LIMIT)
    end

    def search_text(account)
      head = [
        account.display_name,
        username(account),
        acct(account),
        local_domain_acct(account),
        domain_key(account).presence,
      ].compact.map { |part| part.to_s.strip }.reject(&:empty?).join("\n")
      [head, plain_note(account)].reject(&:empty?).join("\n").first(SEARCH_TEXT_LIMIT)
    end

    def software_name(account)
      return '' if account.local?

      GroupDirectory::Eligibility.normalized_software_name(account.node&.info)
    end

    # fedibird, unknown, other, or a known software name. PeerTube is not
    # indexed; this still labels it so a stray document can be filtered.
    def software_bucket(account)
      return 'fedibird' if account.local?

      name = software_name(account)
      return 'unknown' if name.empty?
      return 'peertube' if name == GroupDirectory::Eligibility::PEERTUBE
      return name if GroupDirectory::Eligibility::KNOWN_SOFTWARE.include?(name)

      'other'
    end

    def language_tags(account)
      tags = if account.association(:group_languages).loaded?
               account.group_languages.map(&:tag)
             else
               account.group_languages.pluck(:tag)
             end
      tags.compact.uniq.sort
    end

    # Nil stays nil. The index must not substitute created_at. Elasticsearch
    # omits a nil date; a later sort uses missing: _last to match NULLS LAST.
    def last_status_at(account)
      stat = account.association(:account_stat).target if account.association(:account_stat).loaded?
      stat = AccountStat.find_by(account_id: account.id) unless stat&.persisted?
      return unless stat&.persisted?

      stat.last_status_at
    end
  end
end
