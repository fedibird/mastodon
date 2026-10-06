import { fromJS } from 'immutable';

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
import { buildHashtagTimelinePostingContext } from '../../posting_context/hashtag';
import { materializeComposerText } from '../../posting_context/managed_hashtags';
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
    expect(state.getIn(['context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
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
});

describe('composer routing metadata', () => {
  it('applies a targeted action when called directly', () => {
    const state = composer(undefined, { type: '@@INIT' });
    const next = composer(state, targetComposerAction(changeCompose('other'), 'composer-a'));

    expect(next.get('text')).toEqual('other');
  });
});
