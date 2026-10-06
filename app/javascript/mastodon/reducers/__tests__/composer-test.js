import { fromJS, Set as ImmutableSet } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../uuid', () => ({
  __esModule: true,
  default: () => 'test-idempotency-key',
}));

import { COMPOSE_CHANGE, COMPOSE_RESET, COMPOSE_SUBMIT_SUCCESS, changeCompose, setComposeToStatus } from '../../actions/compose';
import { applyComposerPostingContext, targetComposerAction, toggleComposerManagedHashtag } from '../../actions/composer';
import { STORE_HYDRATE } from '../../actions/store';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import { buildHashtagTimelinePostingContext } from '../../posting_context/hashtag';
import { materializeComposerText } from '../../posting_context/materialize';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';
import compose from '../compose';
import composer from '../composer';

const changeAction = {
  type: COMPOSE_CHANGE,
  text: 'hello',
};

const hydrateAction = {
  type: STORE_HYDRATE,
  state: fromJS({
    compose: {
      text: 'hydrated',
      default_language: 'ja',
    },
  }),
};

describe('composer', () => {
  it('initializes a single composer state', () => {
    const state = composer(undefined, { type: '@@INIT' });

    expect(state.get('text')).toEqual('');
    expect(state.get('privacy')).toBeNull();
    expect(state.getIn(['context', 'key'])).toBeNull();
    expect(state.getIn(['context', 'managed', 'hashtags']).isEmpty()).toBe(true);
    expect(state.getIn(['context', 'managed', 'mentions']).isEmpty()).toBe(true);
    expect(state.getIn(['context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
    expect(state.getIn(['context', 'requirements', 'followingAccounts']).isEmpty()).toBe(true);
    expect(state.getIn(['context', 'constraints', 'allowedVisibilities'])).toBeNull();
  });

  it('handles an ordinary compose action without the primary wrapper', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = composer(state, changeAction);

    expect(next.get('text')).toEqual('hello');
    expect(next.get('dirty')).toBe(true);
  });

  it('ignores root STORE_HYDRATE', () => {
    const state = composer(undefined, { type: '@@INIT' }).set('text', 'keep');

    expect(composer(state, hydrateAction)).toBe(state);
  });
});

describe('compose primary wrapper', () => {
  it('hydrates the primary compose slice', () => {
    const state = composer(undefined, { type: '@@INIT' }).set('text', 'keep');
    const next = compose(state, hydrateAction);

    expect(next.get('default_language')).toEqual('ja');
    expect(next.get('language')).toEqual('ja');
    expect(next.get('text')).toEqual('hydrated');
  });

  it('delegates ordinary actions to the single-instance reducer', () => {
    const state = composer(undefined, { type: '@@INIT' });

    expect(compose(state, changeAction)).toEqual(composer(state, changeAction));
  });

  it('hydrates the primary slice before composer targeting', () => {
    const state = composer(undefined, { type: '@@INIT' }).set('text', 'keep');
    const next = compose(state, {
      ...hydrateAction,
      meta: { composerId: 'composer-a' },
    });

    expect(next.get('default_language')).toEqual('ja');
    expect(next.get('language')).toEqual('ja');
    expect(next.get('text')).toEqual('hydrated');
  });

  it('applies a legacy action to the primary composer', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = compose(state, changeCompose('legacy'));

    expect(next.get('text')).toEqual('legacy');
  });

  it('applies an explicit primary action to the primary composer', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = compose(state, targetComposerAction(changeCompose('primary'), PRIMARY_COMPOSER_ID));

    expect(next.get('text')).toEqual('primary');
  });

  it('leaves the primary composer unchanged for an explicit non-primary action', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = compose(state, targetComposerAction(changeCompose('other'), 'composer-a'));

    expect(next).toBe(state);
  });
});

describe('posting context', () => {
  const applyFoo = applyComposerPostingContext('composer-a', buildHashtagTimelinePostingContext('foo'));
  const applyBar = applyComposerPostingContext('composer-a', buildHashtagTimelinePostingContext('bar'));
  const names = state => state.getIn(['context', 'managed', 'hashtags']).map(tag => tag.get('normalizedName')).toArray();

  it('applies an advisory hashtag and toggles its suppression', () => {
    const applied = composer(undefined, applyFoo);

    expect(names(applied)).toEqual(['foo']);
    expect(applied.getIn(['context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
    expect(applied.get('dirty')).toBe(false);
    expect(applied.get('text')).toEqual('');

    const suppressed = composer(applied, toggleComposerManagedHashtag('composer-a', 'foo'));

    expect(suppressed.getIn(['context', 'suppressions', 'hashtags']).includes('foo')).toBe(true);
    expect(names(suppressed)).toEqual(['foo']);
    expect(suppressed.get('dirty')).toBe(true);
    expect(suppressed.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(suppressed.get('text')).toEqual('');

    const restored = composer(suppressed, toggleComposerManagedHashtag('composer-a', 'foo'));

    expect(restored.getIn(['context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
    expect(names(restored)).toEqual(['foo']);
  });

  it('keeps suppression when the same context is applied again', () => {
    const suppressed = composer(composer(undefined, applyFoo), toggleComposerManagedHashtag('composer-a', 'foo')).set('idempotencyKey', 'kept-key');
    const again = composer(suppressed, applyFoo);

    expect(again.getIn(['context', 'suppressions', 'hashtags']).includes('foo')).toBe(true);
    expect(again.get('idempotencyKey')).toEqual('kept-key');
    expect(again.get('text')).toEqual('');
  });

  it('replaces managed hashtags and clears suppression for a different context', () => {
    const drafted = composer(composer(undefined, applyFoo), changeCompose('hello'));
    const suppressed = composer(drafted, toggleComposerManagedHashtag('composer-a', 'foo')).set('idempotencyKey', 'previous-key');
    const switched = composer(suppressed, applyBar);

    expect(names(switched)).toEqual(['bar']);
    expect(switched.getIn(['context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
    expect(switched.get('text')).toEqual('hello');
    expect(switched.get('idempotencyKey')).toEqual('test-idempotency-key');
  });

  it('clears suppression on reset and submit success while keeping the context', () => {
    const suppressed = composer(composer(undefined, applyFoo), toggleComposerManagedHashtag('composer-a', 'foo'));

    [COMPOSE_RESET, COMPOSE_SUBMIT_SUCCESS].forEach(type => {
      const next = composer(suppressed, { type });

      expect(names(next)).toEqual(['foo']);
      expect(next.getIn(['context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
      expect(next.get('text')).toEqual('');
    });
  });

  it('does not apply timeline context to an existing post or scheduled edit', () => {
    const applied = composer(undefined, applyFoo);
    const editing = composer(applied, setComposeToStatus(fromJS({
      id: 'status-1',
      visibility: 'public',
      sensitive: false,
    }), 'Hello', ''));
    const scheduled = applied.set('text', 'Hello').set('scheduled_status_id', 'sched-1');

    expect(composer(editing, applyBar)).toBe(editing);
    expect(materializeComposerText(editing)).toEqual('Hello');
    expect(composer(scheduled, applyBar)).toBe(scheduled);
    expect(materializeComposerText(scheduled)).toEqual('Hello');
  });

  it('does not toggle suppression while editing an existing or scheduled status', () => {
    const applied = composer(undefined, applyFoo).set('dirty', false).set('idempotencyKey', 'kept-key');
    const editing = composer(applied, setComposeToStatus(fromJS({
      id: 'status-1',
      visibility: 'public',
      sensitive: false,
    }), 'Hello', ''));
    const scheduled = applied.set('text', 'Hello').set('scheduled_status_id', 'sched-1');
    const toggle = toggleComposerManagedHashtag('composer-a', 'foo');

    expect(composer(editing, toggle)).toBe(editing);
    expect(composer(scheduled, toggle)).toBe(scheduled);
    expect(scheduled.getIn(['context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
    expect(scheduled.get('dirty')).toBe(false);
    expect(scheduled.get('idempotencyKey')).toEqual('kept-key');
    expect(editing.getIn(['context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
  });

  it('keeps a hashtag context free of mention, follow, and visibility rules', () => {
    const applied = composer(undefined, applyFoo);

    expect(applied.getIn(['context', 'managed', 'mentions']).isEmpty()).toBe(true);
    expect(applied.getIn(['context', 'requirements', 'followingAccounts']).isEmpty()).toBe(true);
    expect(applied.getIn(['context', 'constraints', 'allowedVisibilities'])).toBeNull();
  });

  it('applies a local group context without widening privacy or rewriting the draft', () => {
    const drafted = composer(undefined, changeCompose('Hello')).set('idempotencyKey', 'previous-key').set('privacy', 'private');
    const applied = composer(drafted, applyComposerPostingContext('composer-a', groupPostingContext));

    expect(applied.get('privacy')).toEqual('private');
    expect(applied.get('text')).toEqual('Hello');
    expect(materializeComposerText(applied)).toEqual('@group Hello');
    expect(applied.get('idempotencyKey')).toEqual('test-idempotency-key');
    expect(applied.getIn(['context', 'managed', 'mentions', 0, 'accountId'])).toEqual('123');
    expect(applied.getIn(['context', 'managed', 'mentions', 0, 'acct'])).toEqual('group');
    expect(applied.getIn(['context', 'managed', 'mentions', 0, 'enforcement'])).toEqual('required');
    expect(applied.getIn(['context', 'requirements', 'followingAccounts', 0, 'accountId'])).toEqual('123');
    expect(applied.getIn(['context', 'requirements', 'followingAccounts', 0, 'ruleId'])).toEqual('group-follow');
    expect(applied.getIn(['context', 'constraints', 'allowedVisibilities']).equals(ImmutableSet(['public', 'unlisted']))).toBe(true);

    const again = composer(applied.set('idempotencyKey', 'kept-key'), applyComposerPostingContext('composer-a', groupPostingContext));

    expect(again.get('idempotencyKey')).toEqual('kept-key');
    expect(again.getIn(['context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
    expect(materializeComposerText(again)).toEqual('@group Hello');
  });

  it('does not materialize a group mention while editing an existing or scheduled status', () => {
    const applied = composer(undefined, applyComposerPostingContext('composer-a', groupPostingContext)).set('text', 'Hello').set('dirty', false).set('idempotencyKey', 'kept-key');
    const editing = composer(applied, setComposeToStatus(fromJS({
      id: 'status-1',
      visibility: 'public',
      sensitive: false,
    }), 'Hello', ''));
    const scheduled = applied.set('scheduled_status_id', 'sched-1');

    expect(materializeComposerText(editing)).toEqual('Hello');
    expect(materializeComposerText(scheduled)).toEqual('Hello');
    expect(composer(editing, applyBar)).toBe(editing);
    expect(composer(scheduled, applyBar)).toBe(scheduled);
    expect(composer(editing, toggleComposerManagedHashtag('composer-a', 'foo'))).toBe(editing);
    expect(composer(scheduled, toggleComposerManagedHashtag('composer-a', 'foo'))).toBe(scheduled);
    expect(scheduled.get('dirty')).toBe(false);
    expect(scheduled.get('idempotencyKey')).toEqual('kept-key');
  });
});

describe('composer routing metadata', () => {
  it('applies a targeted action when called directly', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = composer(state, targetComposerAction(changeCompose('other'), 'composer-a'));

    expect(next.get('text')).toEqual('other');
  });
});
