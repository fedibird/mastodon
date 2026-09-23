# frozen_string_literal: true
hide_followers     = current_user.setting_hide_followers_from_yourself
hide_following     = current_user.setting_hide_following_from_yourself
hide_relationships = hide_followers && hide_following
relationship_title = if hide_followers then t('settings.following') elsif hide_following then t('settings.followers') else t('settings.relationships') end

SimpleNavigation::Configuration.run do |navigation|
  navigation.items do |n|
    n.item :web, safe_join([fa_icon('chevron-left fw'), t('settings.back')]), root_url

    n.item :profile, safe_join([fa_icon('user fw'), t('settings.profile')]), settings_profile_url, if: -> { current_user.functional? } do |s|
      s.item :profile, safe_join([fa_icon('pencil fw'), t('settings.appearance')]), settings_profile_url
      s.item :featured_tags, safe_join([fa_icon('hashtag fw'), t('settings.featured_tags')]), settings_featured_tags_url
      s.item :identity_proofs, safe_join([fa_icon('key fw'), t('settings.identity_proofs')]), settings_identity_proofs_path, highlights_on: %r{/settings/identity_proofs*}, if: proc { current_account.identity_proofs.exists? }
    end

    n.item :preferences, safe_join([fa_icon('cog fw'), t('settings.preferences')]), settings_preferences_url, if: -> { current_user.functional? } do |s|
      s.item :appearance, safe_join([fa_icon('desktop fw'), t('settings.appearance')]), settings_preferences_appearance_url
      s.item :notifications, safe_join([fa_icon('bell fw'), t('settings.notifications')]), settings_preferences_notifications_url
      s.item :favourite_domains, safe_join([fa_icon('users fw'), t('settings.favourite_domains')]), settings_favourite_domains_url
      s.item :favourite_tags, safe_join([fa_icon('hashtag fw'), t('settings.favourite_tags')]), settings_favourite_tags_url
      s.item :safety, safe_join([fa_icon('shield fw'), t('preferences.safety')]), settings_preferences_safety_url
      s.item :other, safe_join([fa_icon('cog fw'), t('preferences.other')]), settings_preferences_other_url
    end

    n.item :follow_and_subscriptions, safe_join([fa_icon('users fw'), t('settings.follow_and_subscriptions')]), hide_relationships ? settings_follow_tags_url : relationships_url, if: -> { current_user.functional? } do |s|
      s.item :relationships, safe_join([fa_icon('users fw'), relationship_title]), relationships_url, highlights_on: %r{/relationships}, unless: -> { hide_relationships }
      s.item :follow_tags, safe_join([fa_icon('hashtag fw'), t('settings.follow_tags')]), settings_follow_tags_url, highlights_on: %r{/follow_tags}
      s.item :account_subscribes, safe_join([fa_icon('users fw'), t('settings.account_subscribes')]), settings_account_subscribes_url, highlights_on: %r{/account_subscribes}
      s.item :domain_subscribes, safe_join([fa_icon('server fw'), t('settings.domain_subscribes')]), settings_domain_subscribes_url, highlights_on: %r{/domain_subscribes}
      s.item :keyword_subscribes, safe_join([fa_icon('search fw'), t('settings.keyword_subscribes')]), settings_keyword_subscribes_url, highlights_on: %r{/keyword_subscribes}
    end

    n.item :filters, safe_join([fa_icon('filter fw'), t('filters.index.title')]), filters_path, highlights_on: %r{/filters}, if: -> { current_user.functional? }
    n.item :statuses_cleanup, safe_join([fa_icon('history fw'), t('settings.statuses_cleanup')]), statuses_cleanup_url, if: -> { current_user.functional? }

    n.item :security, safe_join([fa_icon('lock fw'), t('settings.account')]), edit_user_registration_url do |s|
      s.item :password, safe_join([fa_icon('lock fw'), t('settings.account_settings')]), edit_user_registration_url, highlights_on: %r{/auth/edit|/settings/delete|/settings/migration|/settings/aliases|/settings/login_activities}
      s.item :two_factor_authentication, safe_join([fa_icon('mobile fw'), t('settings.two_factor_authentication')]), settings_two_factor_authentication_methods_url, highlights_on: %r{/settings/two_factor_authentication|/settings/otp_authentication|/settings/security_keys}
      s.item :authorized_apps, safe_join([fa_icon('list fw'), t('settings.authorized_apps')]), oauth_authorized_applications_url
    end

    n.item :data, safe_join([fa_icon('cloud-download fw'), t('settings.import_and_export')]), settings_export_url do |s|
      s.item :import, safe_join([fa_icon('cloud-upload fw'), t('settings.import')]), settings_import_url, if: -> { current_user.functional? }
      s.item :export, safe_join([fa_icon('cloud-download fw'), t('settings.export')]), settings_export_url
    end

    n.item :first_aid, safe_join([fa_icon('medkit fw'), t('first_aid.title')]), first_aid_url, if: -> { current_user.functional? }

    n.item :invites, safe_join([fa_icon('user-plus fw'), t('invites.title')]), invites_path, if: proc { Setting.min_invite_role != 'disabled' && current_user.functional? && current_user.can?(:invite_users) }
    n.item :development, safe_join([fa_icon('code fw'), t('settings.development')]), settings_applications_url, if: -> { current_user.functional? }

    n.item :moderation, safe_join([fa_icon('gavel fw'), t('moderation.title')]), nil, if: proc { role_can?(:view_audit_log, :manage_reports, :manage_users, :manage_invites, :manage_taxonomies, :manage_federation, :manage_blocks) } do |s|
      s.item :action_logs, safe_join([fa_icon('bars fw'), t('admin.action_logs.title')]), admin_action_logs_url, if: -> { role_can?(:view_audit_log) }
      s.item :moderation_evidence_snapshots, safe_join([fa_icon('folder-open fw'), t('admin.moderation_evidence_snapshots.title')]), admin_moderation_evidence_snapshots_url, highlights_on: %r{/admin/moderation_evidence}, if: -> { role_can?(:manage_reports) }
      s.item :action_reviews, safe_join([fa_icon('hourglass-half fw'), action_review_queue_nav_label]), admin_action_reviews_url, highlights_on: %r{/admin/action_reviews(/|\z)}, if: -> { role_can?(:manage_reports) }
      s.item :reports, safe_join([fa_icon('flag fw'), t('admin.reports.title')]), admin_reports_url, highlights_on: %r{/admin/reports}, if: -> { role_can?(:manage_reports) }
      s.item :accounts, safe_join([fa_icon('users fw'), t('admin.accounts.title')]), admin_accounts_url, highlights_on: %r{/admin/accounts|/admin/pending_accounts}, if: -> { role_can?(:manage_users) }
      s.item :invites, safe_join([fa_icon('user-plus fw'), t('admin.invites.title')]), admin_invites_path, if: -> { role_can?(:manage_invites) }
      s.item :tags, safe_join([fa_icon('hashtag fw'), t('admin.tags.title')]), admin_tags_path, highlights_on: %r{/admin/tags}, if: -> { role_can?(:manage_taxonomies) }
      s.item :follow_recommendations, safe_join([fa_icon('user-plus fw'), t('admin.follow_recommendations.title')]), admin_follow_recommendations_path, highlights_on: %r{/admin/follow_recommendations}, if: -> { role_can?(:manage_taxonomies) }
      s.item :instances, safe_join([fa_icon('cloud fw'), t('admin.instances.title')]), admin_instances_url(limited: whitelist_mode? ? nil : '1'), highlights_on: %r{/admin/instances|/admin/domain_blocks|/admin/domain_allows}, if: -> { role_can?(:manage_federation) }
      s.item :email_domain_blocks, safe_join([fa_icon('envelope fw'), t('admin.email_domain_blocks.title')]), admin_email_domain_blocks_url, highlights_on: %r{/admin/email_domain_blocks}, if: -> { role_can?(:manage_blocks) }
      s.item :ip_blocks, safe_join([fa_icon('ban fw'), t('admin.ip_blocks.title')]), admin_ip_blocks_url, highlights_on: %r{/admin/ip_blocks}, if: -> { role_can?(:manage_blocks) }
    end

    n.item :admin, safe_join([fa_icon('cogs fw'), t('admin.title')]), nil, if: proc { role_can?(:view_dashboard, :manage_settings, :manage_rules, :manage_announcements, :manage_custom_emojis, :manage_federation, :manage_blocks, :view_devops, :manage_roles) } do |s|
      s.item :dashboard, safe_join([fa_icon('tachometer fw'), t('admin.dashboard.title')]), admin_dashboard_url, if: -> { role_can?(:view_dashboard) }
      s.item :settings, safe_join([fa_icon('cogs fw'), t('admin.settings.title')]), edit_admin_settings_url, if: -> { role_can?(:manage_settings) }, highlights_on: %r{/admin/settings}
      s.item :roles, safe_join([fa_icon('users fw'), t('admin.roles.title')]), admin_roles_path, highlights_on: %r{/admin/roles}, if: -> { role_can?(:manage_roles) }
      s.item :action_review_settings, safe_join([fa_icon('sliders fw'), t('admin.action_review_settings.title')]), edit_admin_action_review_settings_url, if: -> { role_can?(:manage_settings) }, highlights_on: %r{/admin/action_review_settings}
      s.item :rules, safe_join([fa_icon('gavel fw'), t('admin.rules.title')]), admin_rules_path, highlights_on: %r{/admin/rules}, if: -> { role_can?(:manage_rules) }
      s.item :announcements, safe_join([fa_icon('bullhorn fw'), t('admin.announcements.title')]), admin_announcements_path, highlights_on: %r{/admin/announcements}, if: -> { role_can?(:manage_announcements) }
      s.item :custom_emojis, safe_join([fa_icon('smile-o fw'), t('admin.custom_emojis.title')]), admin_custom_emojis_url, highlights_on: %r{/admin/custom_emojis}, if: -> { role_can?(:manage_custom_emojis) }
      s.item :relays, safe_join([fa_icon('exchange fw'), t('admin.relays.title')]), admin_relays_url, if: -> { role_can?(:manage_federation) && !whitelist_mode? }, highlights_on: %r{/admin/relays}
      s.item :push_subscription_blocks, safe_join([fa_icon('ban fw'), t('admin.push_subscription_blocks.title')]), admin_push_subscription_blocks_url, if: -> { role_can?(:manage_blocks) && !whitelist_mode? }, highlights_on: %r{/admin/push_subscription_blocks}
      s.item :sidekiq, safe_join([fa_icon('diamond fw'), 'Sidekiq']), sidekiq_url, link_html: { target: 'sidekiq' }, if: -> { role_can?(:view_devops) }
      s.item :pghero, safe_join([fa_icon('database fw'), 'PgHero']), pghero_url, link_html: { target: 'pghero' }, if: -> { role_can?(:view_devops) }
    end

    n.item :logout, safe_join([fa_icon('sign-out fw'), t('auth.logout')]), destroy_user_session_url, link_html: { 'data-confirm' => t('auth.logout_confirmation'), 'data-method' => 'delete' }
  end
end
