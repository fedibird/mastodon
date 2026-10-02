# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StatusPublishPreparationWorker do
  subject { described_class.new }

  let(:account) { Fabricate(:account) }
  let(:preparation) { StatusPublishPreparationService.new }

  def stub_get(url, code:, final_url:)
    response = instance_double(HTTP::Response, code: code, uri: final_url)
    request = instance_double(Request)
    allow(request).to receive(:add_headers).and_return(request)
    allow(request).to receive(:perform).and_yield(response)
    allow(Request).to receive(:new).with(:get, url).and_return(request)
  end

  def create_deferred_status(text)
    allow(StatusPublishPreparationWorker).to receive(:perform_async)
    PostStatusService.new.call(account, text: text)
  end

  before do
    allow(DistributionWorker).to receive(:perform_async)
    allow(PriorityDistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    allow(LinkCrawlWorker).to receive(:perform_async)
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(ActivityPub::DeliveryWorker).to receive(:perform_async)
    allow(Rails.logger).to receive(:error)
  end

  it 'publishes after a redirect is stored and does not wait for a preview card' do
    short_url = 'https://bit.ly/abc'
    final_url = 'https://example.com/landed'
    status = create_deferred_status("see #{short_url}")
    stat = StatusStat.find_or_create_by!(status_id: status.id)
    stat.update_columns(updated_at: 1.day.ago)
    stub_get(short_url, code: 200, final_url: final_url)
    stub_get(final_url, code: 200, final_url: final_url)

    subject.perform(status.id)

    link = RedirectLink.find_by!(url: short_url)
    expect(link.redirected_url).to eq final_url
    expect(Formatter.instance.format(status, rest: true)).to include(%(href="#{final_url}"))
    expect(stat.reload.updated_at).to be > 1.hour.ago
    expect(DistributionWorker).to have_received(:perform_async).with(status.id)
    expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id)
    expect(LinkCrawlWorker).to have_received(:perform_async).with(status.id)
    expect(status.reload.preview_cards).to be_empty
    expect(preparation.marked?(status)).to be false
    expect(preparation.redis.smembers("statuses/#{status.id}/processing")).to eq [StatusPublishPreparationService::LINK_CRAWL_MARKER]
    ttl = preparation.redis.ttl("statuses/#{status.id}/processing")
    expect(ttl).to be_positive
    expect(ttl).to be <= StatusPublishPreparationService::LINK_CRAWL_TTL
  end

  it 'puts the final redirect target in the remote mention payload' do
    short_url = 'https://bit.ly/mention'
    final_url = 'https://example.com/mention-target'
    remote = Fabricate(:account, username: 'remote_user', protocol: :activitypub, domain: 'example.com', inbox_url: 'http://example.com/inbox')
    status = create_deferred_status("Hello @remote_user@example.com #{short_url}")
    stub_get(short_url, code: 200, final_url: final_url)
    stub_get(final_url, code: 200, final_url: final_url)
    expect(ActivityPub::DeliveryWorker).not_to have_received(:perform_async)

    subject.perform(status.id)

    expect(ActivityPub::DeliveryWorker).to have_received(:perform_async) do |json, account_id, inbox, _options|
      payload = Oj.load(json)
      content = payload.fetch('object').fetch('content')
      expect(content).to include(%(href="#{final_url}"))
      expect(content).not_to include(%(href="#{short_url}"))
      expect(account_id).to eq status.account_id
      expect(inbox).to eq remote.inbox_url
    end
  end

  it 'notifies a local mention only after the redirect is resolved' do
    alice = Fabricate(:account, username: 'alice')
    status = create_deferred_status('Hello @alice https://bit.ly/local')
    expect(LocalNotificationWorker).not_to have_received(:perform_async)
    stub_get('https://bit.ly/local', code: 200, final_url: 'https://example.com/local')
    stub_get('https://example.com/local', code: 200, final_url: 'https://example.com/local')

    subject.perform(status.id)

    mention = status.mentions.find_by!(account: alice)
    expect(LocalNotificationWorker).to have_received(:perform_async).with(alice.id, mention.id, 'Mention', 'mention')
  end

  it 'reblogs a local group mention only after the redirect is resolved' do
    group = Fabricate(:user, account: Fabricate(:account, username: 'localsquad', actor_type: 'Group')).account
    reblog_service = instance_double(ReblogService, call: nil)
    allow(ReblogService).to receive(:new).and_return(reblog_service)
    status = create_deferred_status('@localsquad https://bit.ly/group')
    expect(reblog_service).not_to have_received(:call)
    stub_get('https://bit.ly/group', code: 200, final_url: 'https://example.com/group')
    stub_get('https://example.com/group', code: 200, final_url: 'https://example.com/group')

    subject.perform(status.id)

    expect(reblog_service).to have_received(:call).with(group, status, hash_including(:visibility))
    expect(DistributionWorker).to have_received(:perform_async).with(status.id)
  end

  it 'does not publish until every redirect URL is resolved' do
    first_url = 'https://bit.ly/one'
    second_url = 'https://t.co/two'
    status = create_deferred_status("#{first_url} #{second_url}")
    stub_get(first_url, code: 200, final_url: 'https://example.com/one')
    stub_get('https://example.com/one', code: 200, final_url: 'https://example.com/one')
    request = instance_double(Request)
    allow(request).to receive(:add_headers).and_return(request)
    allow(request).to receive(:perform).and_raise(HTTP::TimeoutError, 'execution expired')
    allow(Request).to receive(:new).with(:get, second_url).and_return(request)

    expect { subject.perform(status.id) }.to raise_error(ResolveRedirectLinkService::TemporaryFailure)

    expect(RedirectLink.find_by(url: first_url)).to be_present
    expect(RedirectLink.find_by(url: second_url)).to be_nil
    expect(DistributionWorker).not_to have_received(:perform_async)
    expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
    expect(preparation.marked?(status)).to be true
    expect(Rails.logger).to have_received(:error).with(/temporary failure status=#{status.id} url=#{Regexp.escape(second_url)}/)
  end

  it 'publishes once both redirect URLs are resolved' do
    first_url = 'https://bit.ly/both-a'
    second_url = 'https://t.co/both-b'
    status = create_deferred_status("#{first_url} #{second_url}")
    stub_get(first_url, code: 200, final_url: 'https://example.com/both-a')
    stub_get('https://example.com/both-a', code: 200, final_url: 'https://example.com/both-a')
    stub_get(second_url, code: 200, final_url: 'https://example.org/both-b')
    stub_get('https://example.org/both-b', code: 200, final_url: 'https://example.org/both-b')

    subject.perform(status.id)

    expect(DistributionWorker).to have_received(:perform_async).with(status.id).once
    expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id).once
    expect(preparation.marked?(status)).to be false
  end

  it 'retries a temporary failure without publishing or clearing the marker' do
    url = 'https://bit.ly/timeout'
    status = create_deferred_status(url)
    request = instance_double(Request)
    allow(request).to receive(:add_headers).and_return(request)
    allow(request).to receive(:perform).and_raise(HTTP::TimeoutError, 'execution expired')
    allow(Request).to receive(:new).with(:get, url).and_return(request)

    expect { subject.perform(status.id) }.to raise_error(ResolveRedirectLinkService::TemporaryFailure)

    expect(DistributionWorker).not_to have_received(:perform_async)
    expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
    expect(LocalNotificationWorker).not_to have_received(:perform_async)
    expect(preparation.marked?(status)).to be true
    expect(Rails.logger).to have_received(:error).with(/temporary failure status=#{status.id} url=#{Regexp.escape(url)} error=ResolveRedirectLinkService::TemporaryFailure/)
  end

  it 'does not publish a permanently unusable redirect, and clears the marker' do
    url = 'https://bit.ly/gone'
    status = create_deferred_status(url)
    stub_get(url, code: 404, final_url: url)

    subject.perform(status.id)

    expect(DistributionWorker).not_to have_received(:perform_async)
    expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
    expect(preparation.marked?(status)).to be false
    expect(Rails.logger).to have_received(:error).with(/permanent failure status=#{status.id} url=#{Regexp.escape(url)}/)
    expect(Rails.logger).to have_received(:error).with(/unpublished status=#{status.id} urls=#{Regexp.escape(url)}/)
  end

  it 'publishes an identity mapping and keeps the original URL linked' do
    url = 'https://bit.ly/identity'
    status = create_deferred_status("see #{url}")
    stub_get(url, code: 200, final_url: url)

    subject.perform(status.id)

    link = RedirectLink.find_by!(url: url)
    expect(link.redirected_url).to eq url
    html = Formatter.instance.format(status, rest: true)
    expect(html).to include(%(href="#{url}"))
    expect(html).to include('<a ')
    expect(DistributionWorker).to have_received(:perform_async).with(status.id)
    expect(preparation.marked?(status)).to be false
  end

  it 'does not distribute again when preparation runs twice' do
    url = 'https://bit.ly/twice'
    status = create_deferred_status(url)
    stub_get(url, code: 200, final_url: 'https://example.com/twice')
    stub_get('https://example.com/twice', code: 200, final_url: 'https://example.com/twice')

    subject.perform(status.id)
    subject.perform(status.id)

    expect(DistributionWorker).to have_received(:perform_async).once
    expect(ActivityPub::DistributionWorker).to have_received(:perform_async).once
    expect(LinkCrawlWorker).to have_received(:perform_async).once
  end

  it 'logs exhausted retries and does not publish' do
    url = 'https://bit.ly/exhausted'
    status = create_deferred_status(url)
    preparation.mark!(status)
    message = { 'args' => [status.id], 'error_class' => 'ResolveRedirectLinkService::TemporaryFailure', 'error_message' => "temporary HTTP nil for #{url}" }

    described_class.sidekiq_retries_exhausted_block.call(message, ResolveRedirectLinkService::TemporaryFailure.new(url, message['error_message']))

    expect(DistributionWorker).not_to have_received(:perform_async)
    expect(preparation.marked?(status)).to be false
    expect(Rails.logger).to have_received(:error).with(/retries exhausted status=#{status.id} urls=#{Regexp.escape(url)} error=ResolveRedirectLinkService::TemporaryFailure/)
  end

  it 'keeps preparation when publish fails, then completes on retry' do
    url = 'https://bit.ly/publish-retry'
    status = create_deferred_status(url)
    stub_get(url, code: 200, final_url: 'https://example.com/publish-retry')
    stub_get('https://example.com/publish-retry', code: 200, final_url: 'https://example.com/publish-retry')
    allow(ActivityPub::DistributionWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError, 'down')

    expect { subject.perform(status.id) }.to raise_error(Redis::CannotConnectError)
    expect(preparation.marked?(status)).to be true
    expect(PublishStatusService.new.published?(status)).to be false

    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    subject.perform(status.id)

    expect(PublishStatusService.new.published?(status)).to be true
    expect(preparation.marked?(status)).to be false
  end

  it 'does not clear preparation when publish returns without a completion marker' do
    url = 'https://bit.ly/nil-publish'
    status = create_deferred_status(url)
    stub_get(url, code: 200, final_url: 'https://example.com/nil-publish')
    stub_get('https://example.com/nil-publish', code: 200, final_url: 'https://example.com/nil-publish')
    allow_any_instance_of(PublishStatusService).to receive(:call).and_return(nil)

    expect { subject.perform(status.id) }.to raise_error(PublishStatusService::NotPublished)
    expect(preparation.marked?(status)).to be true
    expect(PublishStatusService.new.published?(status)).to be false
    expect(DistributionWorker).not_to have_received(:perform_async)
  end

  it 'does not shorten the processing TTL while another marker remains' do
    status = Fabricate(:status)
    preparation.mark!(status)
    preparation.add_link_crawl!(status)
    preparation.redis.sadd("statuses/#{status.id}/processing", 'RedirectLinkResolveWorker:https://example.test/x')

    preparation.clear!(status)

    members = preparation.redis.smembers("statuses/#{status.id}/processing")
    expect(members).to include(StatusPublishPreparationService::LINK_CRAWL_MARKER, 'RedirectLinkResolveWorker:https://example.test/x')
    expect(members).not_to include(StatusPublishPreparationService::MARKER)
    expect(preparation.redis.ttl("statuses/#{status.id}/processing")).to be > StatusPublishPreparationService::LINK_CRAWL_TTL
  end

  it 'clears the marker when the status has been deleted' do
    status = create_deferred_status('https://bit.ly/deleted')
    status_id = status.id
    status.destroy!

    expect(subject.perform(status_id)).to be true
    expect(preparation.marked?(status_id)).to be false
    expect(DistributionWorker).not_to have_received(:perform_async)
  end
end
