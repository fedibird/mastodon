# frozen_string_literal: true

module Admin::AccountModerationNotesHelper
  def admin_account_link_to(account)
    return if account.nil?

    link_to admin_account_path(account.id), class: name_tag_classes(account), title: account.acct do
      safe_join([
                  image_tag(account.avatar.url, width: 15, height: 15, alt: display_name(account), class: 'avatar'),
                  content_tag(:span, account.acct, class: 'username'),
                ], ' ')
    end
  end

  def admin_account_inline_link_to(account)
    return if account.nil?

    link_to admin_account_path(account.id), class: name_tag_classes(account, true), title: account.acct do
      content_tag(:span, account.acct, class: 'username')
    end
  end

  # The absence of a login User is normal for an approved, locally managed Group.
  # Other local accounts without a User retain the deleted-account appearance.
  def admin_managed_group_without_login?(account)
    account.local? && account.group? && account.user.nil? && account.managed_group.present?
  end

  def admin_deleted_local_account?(account)
    account.local? && account.user.nil? && !admin_managed_group_without_login?(account)
  end

  private

  def name_tag_classes(account, inline = false)
    classes = [inline ? 'inline-name-tag' : 'name-tag']
    classes << 'suspended' if account.suspended? || admin_deleted_local_account?(account)
    classes.join(' ')
  end
end
