# frozen_string_literal: true

require 'rails_helper'

describe 'API routes' do
  describe 'Credentials routes' do
    it 'routes to verify credentials' do
      expect(get('/api/v1/accounts/verify_credentials')).
        to route_to('api/v1/accounts/credentials#show')
    end

    it 'routes to update credentials' do
      expect(patch('/api/v1/accounts/update_credentials')).
        to route_to('api/v1/accounts/credentials#update')
    end
  end

  describe 'Account routes' do
    it 'routes to statuses' do
      expect(get('/api/v1/accounts/user/statuses')).
        to route_to('api/v1/accounts/statuses#index', account_id: 'user')
    end

    it 'routes to followers' do
      expect(get('/api/v1/accounts/user/followers')).
        to route_to('api/v1/accounts/follower_accounts#index', account_id: 'user')
    end

    it 'routes to following' do
      expect(get('/api/v1/accounts/user/following')).
        to route_to('api/v1/accounts/following_accounts#index', account_id: 'user')
    end

    it 'routes to search' do
      expect(get('/api/v1/accounts/search')).
        to route_to('api/v1/accounts/search#show')
    end

    it 'routes to relationships' do
      expect(get('/api/v1/accounts/relationships')).
        to route_to('api/v1/accounts/relationships#index')
    end
  end

  describe 'Statuses routes' do
    it 'routes reblogged_by' do
      expect(get('/api/v1/statuses/123/reblogged_by')).
        to route_to('api/v1/statuses/reblogged_by_accounts#index', status_id: '123')
    end

    it 'routes favourited_by' do
      expect(get('/api/v1/statuses/123/favourited_by')).
        to route_to('api/v1/statuses/favourited_by_accounts#index', status_id: '123')
    end

    it 'routes reblog' do
      expect(post('/api/v1/statuses/123/reblog')).
        to route_to('api/v1/statuses/reblogs#create', status_id: '123')
    end

    it 'routes unreblog' do
      expect(post('/api/v1/statuses/123/unreblog')).
        to route_to('api/v1/statuses/reblogs#destroy', status_id: '123')
    end

    it 'routes favourite' do
      expect(post('/api/v1/statuses/123/favourite')).
        to route_to('api/v1/statuses/favourites#create', status_id: '123')
    end

    it 'routes unfavourite' do
      expect(post('/api/v1/statuses/123/unfavourite')).
        to route_to('api/v1/statuses/favourites#destroy', status_id: '123')
    end

    it 'routes mute' do
      expect(post('/api/v1/statuses/123/mute')).
        to route_to('api/v1/statuses/mutes#create', status_id: '123')
    end

    it 'routes unmute' do
      expect(post('/api/v1/statuses/123/unmute')).
        to route_to('api/v1/statuses/mutes#destroy', status_id: '123')
    end
  end

  describe 'Filter routes' do
    describe 'v1' do
      it 'routes to index' do
        expect(get('/api/v1/filters')).
          to route_to('api/v1/filters#index')
      end

      it 'routes to create' do
        expect(post('/api/v1/filters')).
          to route_to('api/v1/filters#create')
      end

      it 'routes to show' do
        expect(get('/api/v1/filters/1')).
          to route_to('api/v1/filters#show', id: '1')
      end

      it 'routes to update via PUT' do
        expect(put('/api/v1/filters/1')).
          to route_to('api/v1/filters#update', id: '1')
      end

      it 'routes to update via PATCH' do
        expect(patch('/api/v1/filters/1')).
          to route_to('api/v1/filters#update', id: '1')
      end

      it 'routes to destroy' do
        expect(delete('/api/v1/filters/1')).
          to route_to('api/v1/filters#destroy', id: '1')
      end

      it 'does not expose keyword collection actions' do
        expect(get('/api/v1/filters/1/keywords')).
          to route_to(controller: 'application', action: 'raise_not_found', unmatched_route: 'api/v1/filters/1/keywords')
        expect(post('/api/v1/filters/1/keywords')).
          to route_to(controller: 'application', action: 'raise_not_found', unmatched_route: 'api/v1/filters/1/keywords')
      end

      it 'does not expose keyword member actions' do
        expect(get('/api/v1/filters/keywords/1')).
          to route_to(controller: 'application', action: 'raise_not_found', unmatched_route: 'api/v1/filters/keywords/1')
        expect(put('/api/v1/filters/keywords/1')).
          to route_to(controller: 'application', action: 'raise_not_found', unmatched_route: 'api/v1/filters/keywords/1')
        expect(patch('/api/v1/filters/keywords/1')).
          to route_to(controller: 'application', action: 'raise_not_found', unmatched_route: 'api/v1/filters/keywords/1')
        expect(delete('/api/v1/filters/keywords/1')).
          to route_to(controller: 'application', action: 'raise_not_found', unmatched_route: 'api/v1/filters/keywords/1')
      end
    end

    describe 'v2' do
      it 'routes to index' do
        expect(get('/api/v2/filters')).
          to route_to('api/v2/filters#index')
      end

      it 'routes to create' do
        expect(post('/api/v2/filters')).
          to route_to('api/v2/filters#create')
      end

      it 'routes to show' do
        expect(get('/api/v2/filters/1')).
          to route_to('api/v2/filters#show', id: '1')
      end

      it 'routes to update' do
        expect(put('/api/v2/filters/1')).
          to route_to('api/v2/filters#update', id: '1')
      end

      it 'routes to destroy' do
        expect(delete('/api/v2/filters/1')).
          to route_to('api/v2/filters#destroy', id: '1')
      end

      it 'routes nested keywords' do
        expect(get('/api/v2/filters/1/keywords')).
          to route_to('api/v2/filters/keywords#index', filter_id: '1')
        expect(post('/api/v2/filters/1/keywords')).
          to route_to('api/v2/filters/keywords#create', filter_id: '1')
      end

      it 'routes nested statuses' do
        expect(get('/api/v2/filters/1/statuses')).
          to route_to('api/v2/filters/statuses#index', filter_id: '1')
        expect(post('/api/v2/filters/1/statuses')).
          to route_to('api/v2/filters/statuses#create', filter_id: '1')
      end

      it 'routes keyword member actions' do
        expect(get('/api/v2/filters/keywords/1')).
          to route_to('api/v2/filters/keywords#show', id: '1')
        expect(put('/api/v2/filters/keywords/1')).
          to route_to('api/v2/filters/keywords#update', id: '1')
        expect(delete('/api/v2/filters/keywords/1')).
          to route_to('api/v2/filters/keywords#destroy', id: '1')
      end

      it 'routes status member actions' do
        expect(get('/api/v2/filters/statuses/1')).
          to route_to('api/v2/filters/statuses#show', id: '1')
        expect(delete('/api/v2/filters/statuses/1')).
          to route_to('api/v2/filters/statuses#destroy', id: '1')
      end
    end
  end

  describe 'Admin Domain Allow routes' do
    it 'routes to index' do
      expect(get('/api/v1/admin/domain_allows')).
        to route_to('api/v1/admin/domain_allows#index')
    end

    it 'routes to show' do
      expect(get('/api/v1/admin/domain_allows/1')).
        to route_to('api/v1/admin/domain_allows#show', id: '1')
    end

    it 'routes to create' do
      expect(post('/api/v1/admin/domain_allows')).
        to route_to('api/v1/admin/domain_allows#create')
    end

    it 'routes to destroy' do
      expect(delete('/api/v1/admin/domain_allows/1')).
        to route_to('api/v1/admin/domain_allows#destroy', id: '1')
    end
  end

  describe 'Admin Domain Block routes' do
    it 'routes to index' do
      expect(get('/api/v1/admin/domain_blocks')).
        to route_to('api/v1/admin/domain_blocks#index')
    end

    it 'routes to show' do
      expect(get('/api/v1/admin/domain_blocks/1')).
        to route_to('api/v1/admin/domain_blocks#show', id: '1')
    end

    it 'routes to create' do
      expect(post('/api/v1/admin/domain_blocks')).
        to route_to('api/v1/admin/domain_blocks#create')
    end

    it 'routes to update via PUT' do
      expect(put('/api/v1/admin/domain_blocks/1')).
        to route_to('api/v1/admin/domain_blocks#update', id: '1')
    end

    it 'routes to update via PATCH' do
      expect(patch('/api/v1/admin/domain_blocks/1')).
        to route_to('api/v1/admin/domain_blocks#update', id: '1')
    end

    it 'routes to destroy' do
      expect(delete('/api/v1/admin/domain_blocks/1')).
        to route_to('api/v1/admin/domain_blocks#destroy', id: '1')
    end
  end

  describe 'Admin IP Block routes' do
    it 'routes to index' do
      expect(get('/api/v1/admin/ip_blocks')).
        to route_to('api/v1/admin/ip_blocks#index')
    end

    it 'routes to show' do
      expect(get('/api/v1/admin/ip_blocks/1')).
        to route_to('api/v1/admin/ip_blocks#show', id: '1')
    end

    it 'routes to create' do
      expect(post('/api/v1/admin/ip_blocks')).
        to route_to('api/v1/admin/ip_blocks#create')
    end

    it 'routes to update via PUT' do
      expect(put('/api/v1/admin/ip_blocks/1')).
        to route_to('api/v1/admin/ip_blocks#update', id: '1')
    end

    it 'routes to update via PATCH' do
      expect(patch('/api/v1/admin/ip_blocks/1')).
        to route_to('api/v1/admin/ip_blocks#update', id: '1')
    end

    it 'routes to destroy' do
      expect(delete('/api/v1/admin/ip_blocks/1')).
        to route_to('api/v1/admin/ip_blocks#destroy', id: '1')
    end
  end

  describe 'Timeline routes' do
    it 'routes to home timeline' do
      expect(get('/api/v1/timelines/home')).
        to route_to('api/v1/timelines/home#show')
    end

    it 'routes to public timeline' do
      expect(get('/api/v1/timelines/public')).
        to route_to('api/v1/timelines/public#show')
    end

    it 'routes to tag timeline' do
      expect(get('/api/v1/timelines/tag/test')).
        to route_to('api/v1/timelines/tag#show', id: 'test')
    end
  end
end
