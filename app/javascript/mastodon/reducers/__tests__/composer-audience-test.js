import { fromJS } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../uuid', () => ({
  __esModule: true,
  default: () => 'test-idempotency-key',
}));

import { COMPOSE_CHANGE, COMPOSE_REPLY, COMPOSE_REPLY_CANCEL, COMPOSE_RESET, COMPOSE_QUOTE, COMPOSE_QUOTE_CANCEL, COMPOSE_SCHEDULED_EDIT_CANCEL } from '../../actions/compose';
import { applyComposerPostingContext } from '../../actions/composer';
import { REDRAFT } from '../../actions/statuses';
import { materializeComposerText } from '../../posting_context/materialize';
import composer from '../composer';

const audienceContext = (accountId, key = 'protocol:activitypub:audience') => ({
  key,
  source: { id: 'protocol:activitypub', revision: 1 },
  managed: { hashtags: [], mentions: [] },
  requirements: { followingAccounts: [] },
  constraints: { allowedVisibilities: ['public', 'unlisted'] },
  protocol: {
    activityPub: {
      audience: accountId ? {
        accountId,
        acct: 'group@example.com',
        enforcement: 'required',
        ruleId: 'fep-1b12-group-audience',
      } : null,
    },
  },
});

const replyStatus = () => fromJS({
  id: 'parent-1',
  visibility: 'public',
  language: 'en',
  spoiler_text: '',
  mentions: [],
  account: { id: 'other', acct: 'other' },
});

describe('ActivityPub audience context', () => {
  it('stores an audience target separately from mentions', () => {
    const applied = composer(undefined, applyComposerPostingContext('composer-a', audienceContext('456')));

    expect(applied.getIn(['context', 'protocol', 'activityPub', 'audience']).toJS()).toEqual({
      accountId: '456',
      acct: 'group@example.com',
      enforcement: 'required',
      ruleId: 'fep-1b12-group-audience',
    });
    expect(applied.getIn(['context', 'managed', 'mentions']).isEmpty()).toBe(true);
    expect(applied.get('text')).toEqual('');
    expect(materializeComposerText(applied.set('text', 'Hello'))).toEqual('Hello');
  });

  it('replaces the audience when the context changes and clears it on detach', () => {
    const drafted = composer(undefined, { type: COMPOSE_CHANGE, text: 'Hello' }).set('idempotencyKey', 'previous-key');
    const applied = composer(drafted, applyComposerPostingContext('composer-a', audienceContext('456')));

    expect(applied.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('456');
    expect(applied.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(applied.get('text')).toEqual('Hello');

    const again = composer(applied.set('idempotencyKey', 'kept-key'), applyComposerPostingContext('composer-a', audienceContext('456')));

    expect(again.get('idempotencyKey')).toEqual('kept-key');
    expect(again.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('456');

    const sameKey = composer(again.set('idempotencyKey', 'kept-key'), applyComposerPostingContext('composer-a', audienceContext('789')));

    expect(sameKey.getIn(['context', 'key'])).toEqual('protocol:activitypub:audience');
    expect(sameKey.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('789');
    expect(sameKey.get('idempotencyKey')).toEqual('test-idempotency-key');

    const switched = composer(sameKey.set('idempotencyKey', 'kept-key'), applyComposerPostingContext('composer-a', audienceContext('111', 'protocol:activitypub:other')));

    expect(switched.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('111');
    expect(switched.get('idempotencyKey')).toEqual('test-idempotency-key');

    const detached = composer(switched.set('idempotencyKey', 'kept-key'), applyComposerPostingContext('composer-a', null));

    expect(detached.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
    expect(detached.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(detached.get('text')).toEqual('Hello');
  });
});

describe('scheduled audience redraft', () => {
  const redraft = (state, status) => composer(state, {
    type: REDRAFT,
    raw_text: status.get('text'),
    status,
    context_references: fromJS([]),
  });

  const scheduledStatus = (overrides = {}) => fromJS({
    text: 'Hello',
    visibility: 'public',
    spoiler_text: '',
    media_attachments: [],
    scheduled_status_id: 'sched-1',
    audience_account_id: '456',
    ...overrides,
  });

  it('restores the saved audience target onto the scheduled draft', () => {
    const next = redraft(composer(undefined, { type: '@@INIT' }), scheduledStatus());

    expect(next.get('scheduled_status_id')).toEqual('sched-1');
    expect(next.get('draft_audience_account_id')).toEqual('456');
    expect(next.get('text')).toEqual('Hello');
  });

  it('keeps the retained target when another posting context is applied', () => {
    const restored = redraft(composer(undefined, { type: '@@INIT' }), scheduledStatus());
    const next = composer(restored, applyComposerPostingContext('composer-a', audienceContext('789', 'protocol:other')));

    expect(next).toBe(restored);
    expect(next.get('scheduled_status_id')).toEqual('sched-1');
    expect(next.get('draft_audience_account_id')).toEqual('456');
    expect(next.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
  });

  it('does not clear the retained target when the text changes', () => {
    const restored = redraft(composer(undefined, { type: '@@INIT' }), scheduledStatus());
    const next = composer(restored, { type: COMPOSE_CHANGE, text: 'Hello again' });

    expect(next.get('text')).toEqual('Hello again');
    expect(next.get('scheduled_status_id')).toEqual('sched-1');
    expect(next.get('draft_audience_account_id')).toEqual('456');
  });

  it('clears the retained target when the scheduled draft becomes a new post', () => {
    const restored = redraft(composer(undefined, { type: '@@INIT' }), scheduledStatus());
    const actions = [
      { type: COMPOSE_RESET },
      { type: COMPOSE_REPLY_CANCEL },
      { type: COMPOSE_QUOTE_CANCEL },
      { type: COMPOSE_SCHEDULED_EDIT_CANCEL },
      { type: COMPOSE_REPLY, status: replyStatus(), context_references: [] },
      { type: COMPOSE_QUOTE, status: replyStatus() },
    ];

    actions.forEach(action => {
      const next = composer(restored, action);

      expect(next.get('scheduled_status_id')).toBeNull();
      expect(next.get('draft_audience_account_id')).toBeNull();
    });
  });

  it('does not restore an audience target for an ordinary redraft', () => {
    const next = redraft(composer(undefined, { type: '@@INIT' }).set('draft_audience_account_id', '456'), scheduledStatus({
      scheduled_status_id: null,
    }));

    expect(next.get('scheduled_status_id')).toBeNull();
    expect(next.get('draft_audience_account_id')).toBeNull();
  });
});
