# frozen_string_literal: true

class InitialStatePresenter < ActiveModelSerializers::Model
  attributes :settings, :push_subscription, :token,
             :current_account, :admin, :text, :visibility, :signed_in_user,
             :post_draft_sync
end
