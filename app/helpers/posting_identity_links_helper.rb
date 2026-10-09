# frozen_string_literal: true

module PostingIdentityLinksHelper
  def posting_identity_scope_labels(scopes)
    Array(scopes).map { |scope| I18n.t("posting_identity_links.scopes.#{scope}") }.join(I18n.t('posting_identity_links.scopes.joiner'))
  end
end
