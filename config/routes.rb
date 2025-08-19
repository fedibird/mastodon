# frozen_string_literal: true

require 'sidekiq_unique_jobs/web' if ENV['ENABLE_SIDEKIQ_UNIQUE_JOBS_UI'] == true
require 'sidekiq-scheduler/web'

class RedirectWithVary < ActionDispatch::Routing::PathRedirect
  def build_response(req)
    super.tap do |response|
      response.headers['Vary'] = 'Origin, Accept'
    end
  end
end

def redirect_with_vary(path)
  RedirectWithVary.new(301, path)
end

Rails.application.routes.draw do
  root 'home#index'

  mount LetterOpenerWeb::Engine, at: 'letter_opener' if Rails.env.development?

  get 'health', to: 'health#show'

  authenticate :user, lambda { |u| u.admin? } do
    mount Sidekiq::Web, at: 'sidekiq', as: :sidekiq
    mount PgHero::Engine, at: 'pghero', as: :pghero
  end

  use_doorkeeper do
    controllers authorizations: 'oauth/authorizations',
                authorized_applications: 'oauth/authorized_applications',
                tokens: 'oauth/tokens'
  end

  scope path: '.well-known' do
    scope module: :well_known do
      get 'host-meta', to: 'host_meta#show', as: :host_meta, defaults: { format: 'xml' }
      get 'nodeinfo', to: 'nodeinfo#index', as: :nodeinfo, defaults: { format: 'json' }
      get 'webfinger', to: 'webfinger#show', as: :webfinger
      get 'keybase-proof-config', to: 'keybase_proof_config#show'
    end
    get 'change-password', to: redirect('/auth/edit')
  end

  get '/nodeinfo/2.0', to: 'well_known/nodeinfo#show', as: :nodeinfo_schema

  get 'manifest', to: 'manifests#show', defaults: { format: 'json' }
  get 'intent', to: 'intents#show'
  get 'custom.css', to: 'custom_css#show', as: :custom_css

  resource :instance_actor, path: 'actor', only: [:show] do
    resource :inbox, only: [:create], module: :activitypub
    resource :outbox, only: [:show], module: :activitypub
  end

  devise_scope :user do
    get '/invite/:invite_code', to: 'auth/registrations#new', as: :public_invite

    namespace :auth do
      resource :setup, only: [:show, :update], controller: :setup
      resource :challenge, only: [:create], controller: :challenges
      get 'sessions/security_key_options', to: 'sessions#webauthn_options'
    end
  end

  devise_for :users, path: 'auth', format: false, controllers: {
    omniauth_callbacks: 'auth/omniauth_callbacks',
    sessions:           'auth/sessions',
    registrations:      'auth/registrations',
    passwords:          'auth/passwords',
    confirmations:      'auth/confirmations',
  }

  with_options constraints: ->(req) { req.format.nil? || req.format.html? } do
    get '/users/:username', to: redirect_with_vary('/@%{username}')
    get '/users/:username/following', to: redirect_with_vary('/@%{username}/following')
    get '/users/:username/followers', to: redirect_with_vary('/@%{username}/followers')
    get '/users/:username/statuses/:id', to: redirect_with_vary('/@%{username}/%{id}')
  end

  get '/authorize_follow', to: redirect { |_, request| "/authorize_interaction?#{request.params.to_query}" }

  resources :accounts, path: 'users', controller: 'activitypub/accounts', only: [:show], param: :username do
    get :remote_follow,  to: 'remote_follow#new'
    post :remote_follow, to: 'remote_follow#create'

    resources :statuses, controller: 'activitypub/statuses', only: [:show] do
      member do
        get :activity
        get :embed
      end

      resources :replies, only: [:index], module: :activitypub
      resources :references, only: [:index], module: :activitypub
      resources :emoji_reactions, only: [:index], module: :activitypub
    end

    resources :followers, only: [:index], controller: 'activitypub/follower_accounts'
    resources :following, only: [:index], controller: 'activitypub/following_accounts'
    resource :follow, only: [:create], controller: :account_follow
    resource :unfollow, only: [:create], controller: :account_unfollow

    resource :outbox, only: [:show], module: :activitypub
    resource :inbox, only: [:create], module: :activitypub
    resource :claim, only: [:create], module: :activitypub
    resources :collections, only: [:show], module: :activitypub
    resource :followers_synchronization, only: [:show], module: :activitypub
  end

  resource :inbox, only: [:create], module: :activitypub
  resources :contexts, only: [:show], module: :activitypub

  constraints(username: %r{[^@/.]+}) do
    with_options to: 'accounts#show' do
      get '/@:username', as: :short_account
      get '/@:username/with_replies', as: :short_account_with_replies
      get '/@:username/media', as: :short_account_media
      get '/@:username/tagged/:tag', as: :short_account_tag
      get '/@:username/tagged/:tag/media', as: :short_account_tag_media
    end
  end

  constraints(account_username: %r{[^@/.]+}) do
    get '/@:account_username/following', to: 'following_accounts#index', as: :short_account_following_index
    get '/@:account_username/followers', to: 'follower_accounts#index', as: :short_account_followers_index
    get '/@:account_username/:id', to: 'statuses#show', as: :short_account_status
    get '/@:account_username/:id/embed', to: 'statuses#embed', as: :embed_short_account_status
    get '/@:account_username/:id/references', to: 'statuses#references', as: :references_short_account_status
  end

  get  '/interact/:id', to: 'remote_interaction#new', as: :remote_interaction
  post '/interact/:id', to: 'remote_interaction#create'

  get '/explore', to: 'directories#index', as: :explore
  get '/server_explore', to: 'server_directories#index', as: :server_explore
  get '/settings', to: redirect('/settings/profile')

  namespace :settings do
    resource :profile, only: [:show, :update] do
      resources :pictures, only: :destroy
    end

    get :preferences, to: redirect('/settings/preferences/appearance')

    namespace :preferences do
      resource :appearance, only: [:show, :update], controller: :appearance
      resource :notifications, only: [:show, :update]
      resource :safety, only: [:show, :update], controller: :safety
      resource :other, only: [:show, :update], controller: :other
    end

    resource :import, only: [:show, :create]
    resource :export, only: [:show, :create]

    namespace :exports, constraints: { format: :csv } do
      resources :follows, only: :index, controller: :following_accounts
      resources :blocks, only: :index, controller: :blocked_accounts
      resources :mutes, only: :index, controller: :muted_accounts
      resources :lists, only: :index, controller: :lists
      resources :domain_blocks, only: :index, controller: :blocked_domains
      resources :bookmarks, only: :index, controller: :bookmarks
      resources :account_subscribings, only: :index, controller: :account_subscribings
    end

    resources :two_factor_authentication_methods, only: [:index] do
      collection do
        post :disable
      end
    end

    resource :otp_authentication, only: [:show, :create], controller: 'two_factor_authentication/otp_authentication'

    resources :webauthn_credentials, only: [:index, :new, :create, :destroy],
              path: 'security_keys',
              controller: 'two_factor_authentication/webauthn_credentials' do

      collection do
        get :options
      end
    end

    namespace :two_factor_authentication do
      resources :recovery_codes, only: [:create]
      resource :confirmation, only: [:new, :create]
    end

    resources :identity_proofs, only: [:index, :new, :create, :destroy]

    resources :applications, except: [:edit] do
      member do
        post :regenerate
      end
    end

    resource :delete, only: [:show, :destroy]
    resource :migration, only: [:show, :create]

    namespace :migration do
      resource :redirect, only: [:new, :create, :destroy]
    end

    resources :aliases, only: [:index, :create, :destroy]
    resources :sessions, only: [:destroy]
    resources :featured_tags, only: [:index, :create, :destroy]
    resources :favourite_domains, only: [:index, :create, :destroy]
    resources :favourite_tags, only: [:index, :create, :destroy]
    resources :follow_tags, except: [:show]
    resources :account_subscribes, except: [:show]
    resources :domain_subscribes, except: [:show]
    resources :keyword_subscribes, except: [:show]
    resources :login_activities, only: [:index]
  end

  resources :media, only: [:show] do
    get :player
  end

  resources :tags,   only: [:show]
  resources :emojis, only: [:show]
  resources :emoji_reactions, only: [:show]
  resources :invites, only: [:index, :create, :destroy]
  resources :filters, except: [:show] do
    resources :statuses, only: [:index], controller: 'filters/statuses' do
      collection do
        post :batch
      end
    end
  end
  resources :generators, only: [:show]
  resource :relationships, only: [:show, :update]
  resource :statuses_cleanup, controller: :statuses_cleanup, only: [:show, :update]
  resource :first_aid, controller: :first_aid, only: [:show] do
    post :reset_server_settings
    post :reset_web_settings
    post :reset_frequently_used_emojis
    post :reset_counters
    post :reset_home_feed
  end

  get '/public', to: 'public_timelines#show', as: :public_timeline
  get '/media_proxy/:id/(*any)', to: 'media_proxy#show', as: :media_proxy, format: false
  get '/backups/:id/download', to: 'backups#download', as: :download_backup, format: false

  resource :authorize_interaction, only: [:show, :create]
  resource :share, only: [:show, :create]

  namespace :admin do
    get '/dashboard', to: 'dashboard#index'

    resources :domain_allows, only: [:new, :create, :show, :destroy]
    resources :domain_blocks, only: [:new, :create, :show, :destroy, :update, :edit]

    resources :email_domain_blocks, only: [:index, :new, :create, :destroy]
    resources :action_logs, only: [:index]
    resources :warning_presets, except: [:new]

    resources :announcements, except: [:show] do
      member do
        post :publish
        post :unpublish
      end
    end

    resource :settings, only: [:edit, :update]
    resources :site_uploads, only: [:destroy]

    resources :invites, only: [:index, :create, :destroy] do
      collection do
        post :deactivate_all
      end
    end

    resources :relays, only: [:index, :new, :create, :destroy] do
      member do
        post :enable
        post :disable
      end
    end

    resources :instances, only: [:index, :show], constraints: { id: /[^\/]+/ } do
      member do
        post :clear_delivery_errors
        post :restart_delivery
        post :stop_delivery
      end
    end

    resources :rules

    resources :reports, only: [:index, :show] do
      member do
        post :assign_to_self
        post :unassign
        post :reopen
        post :resolve
      end

      resources :reported_statuses, only: [:create]
    end

    resources :report_notes, only: [:create, :destroy]

    resources :accounts, only: [:index, :show, :destroy] do
      member do
        post :enable
        post :unsensitive
        post :unsilence
        post :unsuspend
        post :redownload
        post :remove_avatar
        post :remove_header
        post :memorialize
        post :approve
        post :reject
      end

      resource :change_email, only: [:show, :update]
      resource :reset, only: [:create]
      resource :action, only: [:new, :create], controller: 'account_actions'
      resources :statuses, only: [:index, :show, :create, :update, :destroy]
      resources :relationships, only: [:index]

      resource :confirmation, only: [:create] do
        collection do
          post :resend
        end
      end

      resource :role, only: [] do
        member do
          post :promote
          post :demote
        end
      end

      resource :priority, only: [] do
        member do
          post :default
          post :high
          post :low
        end
      end

      resource :type, only: [] do
        member do
          post :person
          post :service
          post :group
        end
      end
    end

    resources :pending_accounts, only: [:index] do
      collection do
        post :approve_all
        post :reject_all
        post :batch
      end
    end

    resources :users, only: [] do
      resource :two_factor_authentication, only: [:destroy]
      resource :sign_in_token_authentication, only: [:create, :destroy]
    end

    resources :custom_emojis, only: [:index, :new, :create, :update, :edit] do
      collection do
        post :batch
      end
    end

    resources :ip_blocks, only: [:index, :new, :create] do
      collection do
        post :batch
      end
    end

    resources :account_moderation_notes, only: [:create, :destroy]
    resource :follow_recommendations, only: [:show, :update]

    resources :tags, only: [:index, :show, :update] do
      collection do
        post :approve_all
        post :reject_all
        post :batch
      end
    end

    resources :push_subscription_blocks, except: [:show] do
      member do
        post :enable
        post :disable
      end
    end
  end

  get '/admin', to: redirect('/admin/dashboard', status: 302)

  namespace :api, format: false do
    # OEmbed
    get '/oembed', to: 'oembed#show', as: :oembed

    # Identity proofs
    get :proofs, to: 'proofs#index'

    # JSON / REST API
    namespace :v1 do
      namespace :statuses do
        get :updated
      end

      resources :statuses, only: [:index, :create, :show, :destroy] do
        scope module: :statuses do
          resources :reblogged_by, controller: :reblogged_by_accounts, only: :index
          resources :favourited_by, controller: :favourited_by_accounts, only: :index
          resources :emoji_reactioned_by, controller: :emoji_reactioned_by, only: :index
          resources :referred_by, controller: :referred_by_statuses, only: :index
          resources :mentioned_by, controller: :mentioned_by_accounts, only: :index
          resource :reblog, only: :create
          post :unreblog, to: 'reblogs#destroy'

          resource :favourite, only: :create
          post :unfavourite, to: 'favourites#destroy'

          resource :bookmark, only: :create
          post :unbookmark, to: 'bookmarks#destroy'

          resource :mute, only: :create
          post :unmute, to: 'mutes#destroy'

          resource :pin, only: :create
          post :unpin, to: 'pins#destroy'

          resources :emoji_reactions, only: [:update, :destroy], constraints: { id: %r{[^/]+} }
          post :emoji_unreaction, to: 'emoji_reactions#destroy'

          # compatibility for glitch social
          post '/react/:id', to: 'emoji_reactions#update', constraints: { id: %r{[^/]+} }
          post '/unreact/:id', to: 'emoji_reactions#destroy', constraints: { id: %r{[^/]+} }

          resource :history, only: :show
        end

        member do
          get :context
          post :expire
        end
      end

      namespace :timelines do
        resource :home, only: :show, controller: :home
        resource :public, only: :show, controller: :public
        resources :tag, only: :show
        resources :list, only: :show
        resources :group, only: :show
        resource :personal, only: :show, controller: :personal
      end

      get '/streaming', to: 'streaming#index'
      get '/streaming/(*any)', to: 'streaming#index'

      resources :custom_emojis, only: [:index, :show], constraints: { id: %r{[^/]+} } do
        member do
          post :fetch
        end
      end

      resources :suggestions, only: [:index, :destroy]
      resources :scheduled_statuses, only: [:index, :show, :update, :destroy]
      resources :preferences, only: [:index]

      resources :announcements, only: [:index] do
        scope module: :announcements do
          resources :reactions, only: [:update, :destroy]
        end

        member do
          post :dismiss
        end
      end

      # namespace :crypto do
      #   resources :deliveries, only: :create

      #   namespace :keys do
      #     resource :upload, only: [:create]
      #     resource :query,  only: [:create]
      #     resource :claim,  only: [:create]
      #     resource :count,  only: [:show]
      #   end

      #   resources :encrypted_messages, only: [:index] do
      #     collection do
      #       post :clear
      #     end
      #   end
      # end

      resources :conversations, only: [:index, :destroy] do
        member do
          post :read
        end
      end

      resources :media,           only: [:create, :update, :show]
      resources :blocks,          only: [:index]
      resources :mutes,           only: [:index]
      resources :favourites,      only: [:index]
      resources :bookmarks,       only: [:index]
      resources :emoji_reactions, only: [:index]
      resources :reports,         only: [:create]
      resources :trends,          only: [:index]
      resources :filters,         only: [:index, :create, :show, :update, :destroy] do
        resources :keywords, only: [:index, :create], controller: 'filters/keywords'
      end
      resources :endorsements,    only: [:index]
      resources :markers,         only: [:index, :create]

      namespace :filters do
        resources :keywords, only: [:show, :update, :destroy]
      end

      namespace :apps do
        get :verify_credentials, to: 'credentials#show'
      end

      resources :apps, only: [:create]

      namespace :emails do
        resources :confirmations, only: [:create]
      end

      resource :instance, only: [:show] do
        scope module: :instances do
          resources :peers, only: [:index]
          resources :rules, only: [:index]
          # resources :domain_blocks, only: [:index]
          # resource :privacy_policy, only: [:show]
          # resource :extended_description, only: [:show]
          # resource :translation_languages, only: [:show]
          # resource :languages, only: [:show]
          resource :activity, only: [:show], controller: :activity
        end
      end

      resource :domain_blocks, only: [:show, :create, :destroy]

      resource :directory,       only: [:show]
      resource :group_directory, only: [:show]

      resources :follow_requests, only: [:index] do
        member do
          post :authorize
          post :reject
        end
      end

      resources :notifications, only: [:index, :show] do
        collection do
          post :clear
        end

        member do
          post :dismiss
        end
      end

      namespace :accounts do
        get :verify_credentials, to: 'credentials#show'
        patch :update_credentials, to: 'credentials#update'
        resource :search, only: :show, controller: :search
        resource :lookup, only: :show, controller: :lookup
        resources :relationships, only: :index
        resources :subscribing, only: :index, controller: 'subscribing_accounts'
      end

      resources :accounts, only: [:index, :create, :show] do
        resources :statuses, only: :index, controller: 'accounts/statuses'
        resources :followers, only: :index, controller: 'accounts/follower_accounts'
        resources :following, only: :index, controller: 'accounts/following_accounts'
        resources :lists, only: :index, controller: 'accounts/lists'
        resources :circles, only: :index, controller: 'accounts/circles'
        resources :identity_proofs, only: :index, controller: 'accounts/identity_proofs'
        resources :featured_tags, only: :index, controller: 'accounts/featured_tags'
        resources :conversations, only: :index, controller: 'accounts/conversations'

        member do
          post :follow
          post :unfollow
          post :remove_from_followers
          post :subscribe
          post :unsubscribe
          post :block
          post :unblock
          post :mute
          post :unmute
        end

        resource :pin, only: :create, controller: 'accounts/pins'
        post :unpin, to: 'accounts/pins#destroy'
        resource :note, only: :create, controller: 'accounts/notes'
      end

      resources :tags, only: [:show] do
        member do
          post :follow
          post :unfollow
        end
      end

      resources :followed_tags, only: [:index]

      resources :lists, only: [:index, :create, :show, :update, :destroy] do
        resource :accounts, only: [:show, :create, :destroy], controller: 'lists/accounts'
        resource :subscribes, only: [:show, :create, :destroy], controller: 'lists/subscribes'

        member do
          post :favourite
          post :unfavourite
        end
    end

      resources :circles, only: [:index, :create, :show, :update, :destroy] do
        resource :accounts, only: [:show, :create, :destroy], controller: 'circles/accounts'
      end

      namespace :featured_tags do
        get :suggestions, to: 'suggestions#index'
      end

      resources :featured_tags, only: [:index, :create, :destroy]
      resources :favourite_domains, only: [:index, :create, :show, :update, :destroy]
      resources :favourite_tags, only: [:index, :create, :show, :update, :destroy]
      resources :follow_tags, only: [:index, :create, :show, :update, :destroy]
      resources :domain_subscribes, only: [:index, :create, :show, :update, :destroy]
      resources :keyword_subscribes, only: [:index, :create, :show, :update, :destroy]

      resources :polls, only: [:create, :show] do
        resources :votes, only: :create, controller: 'polls/votes'
      end

      namespace :push do
        resource :subscription, only: [:create, :show, :update, :destroy]
      end

      namespace :admin do
        resources :accounts, only: [:index, :show, :destroy] do
          member do
            post :enable
            post :unsensitive
            post :unsilence
            post :unsuspend
            post :approve
            post :reject
          end

          resource :action, only: [:create], controller: 'account_actions'
        end

        resources :reports, only: [:index, :show] do
          member do
            post :assign_to_self
            post :unassign
            post :reopen
            post :resolve
          end
        end
      end
    end

    namespace :v2 do
      get '/search', to: 'search#index', as: :search

      resources :media, only: [:create]
      resources :suggestions, only: [:index]
      resource :instance, only: [:show]
      resources :filters, only: [:index, :create, :show, :update, :destroy] do
        scope module: :filters do
          resources :keywords, only: [:index, :create]
          resources :statuses, only: [:index, :create]
        end
      end
  
      namespace :filters do
        resources :keywords, only: [:show, :update, :destroy]
        resources :statuses, only: [:show, :destroy]
      end
    end

    namespace :web do
      resource :settings, only: [:update]
      resource :embed, only: [:create]
      resources :push_subscriptions, only: [:create] do
        member do
          put :update
        end
      end
    end
  end

  get '/web/(*any)', to: 'home#index', as: :web

  get '/about',        to: 'about#show'
  get '/about/more',   to: 'about#more'
  get '/terms',        to: 'about#terms'

  match '/', via: [:post, :put, :patch, :delete], to: 'application#raise_not_found', format: false
  match '*unmatched_route', via: :all, to: 'application#raise_not_found', format: false
end
