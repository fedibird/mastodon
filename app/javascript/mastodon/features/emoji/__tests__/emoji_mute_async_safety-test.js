import { Map as ImmutableMap } from 'immutable';

jest.mock('mastodon/initial_state_data', () => ({
  meta: { me: '1', access_token: 'token' },
}));

jest.mock('mastodon/api', () => {
  const get = jest.fn();
  return { __esModule: true, default: jest.fn(() => ({ get })) };
});

import api from 'mastodon/api';
import reducer from 'mastodon/reducers/emoji_mutes';
import {
  EMOJI_MUTES_APPLY,
  EMOJI_MUTES_FAIL,
  EMOJI_MUTES_RESET,
  EMOJI_MUTES_REVISION,
  syncEmojiMutes,
} from 'mastodon/actions/emoji_mutes';
import {
  appliedEmojiMuteRevision,
  currentEmojiMutes,
  emojiMuteDocumentReady,
  loadEmojiMutes,
  noteEmojiMutesChanged,
  observedEmojiMuteRevision,
  resetEmojiMuteSession,
  resetEmojiMuteStoreForTests,
} from '../emoji_mute_store';

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
};

const document = (revision, name) => ({
  revision,
  emoji_mutes: [{ id: name, emoji: { kind: 'unicode', native: name }, effects: { replace_in_text: true } }],
});

describe('emoji mute async safety (B5)', () => {
  beforeEach(() => {
    resetEmojiMuteStoreForTests();
    api().get.mockReset();
  });

  it('does not treat an unfetched document as an empty confirmed rule set', () => {
    expect(emojiMuteDocumentReady()).toBe(false);
    expect(appliedEmojiMuteRevision()).toBeNull();

    api().get.mockResolvedValueOnce({ data: { revision: '0', emoji_mutes: [] } });
    return loadEmojiMutes().then(() => {
      expect(emojiMuteDocumentReady()).toBe(true);
      expect(currentEmojiMutes()).toEqual([]);
    });
  });

  it('discards the late first GET when a newer streamed revision wins', async () => {
    const first = deferred();
    const second = deferred();
    api().get.mockImplementationOnce(() => first.promise).mockImplementationOnce(() => second.promise);

    const pendingFirst = loadEmojiMutes();
    const pendingSecond = noteEmojiMutesChanged({ revision: '9' });
    expect(observedEmojiMuteRevision()).toBe('9');
    expect(emojiMuteDocumentReady()).toBe(false);

    second.resolve({ data: document('9', '✅') });
    await pendingSecond;
    first.resolve({ data: document('8', '❌') });
    await pendingFirst;

    expect(emojiMuteDocumentReady()).toBe(true);
    expect(appliedEmojiMuteRevision()).toBe('9');
    expect(currentEmojiMutes()).toEqual(document('9', '✅').emoji_mutes);
  });

  it('rejects a response below the revision observed while it was in flight', async () => {
    api().get.mockResolvedValueOnce({ data: document('4', 'old') });
    await loadEmojiMutes();
    expect(emojiMuteDocumentReady()).toBe(true);

    const late = deferred();
    api().get.mockImplementationOnce(() => late.promise);
    const pending = noteEmojiMutesChanged({ revision: '5' });
    expect(emojiMuteDocumentReady()).toBe(false);
    late.resolve({ data: document('4', 'older') });
    await pending;
    expect(appliedEmojiMuteRevision()).toBe('4');
    expect(currentEmojiMutes()).toEqual(document('4', 'old').emoji_mutes);
    expect(emojiMuteDocumentReady()).toBe(false);
  });

  it('invalidates an in-flight request at the session boundary', async () => {
    const old = deferred();
    api().get.mockImplementationOnce(() => old.promise);
    const pending = loadEmojiMutes();
    resetEmojiMuteSession();

    old.resolve({ data: document('100', 'private') });
    await pending;

    expect(emojiMuteDocumentReady()).toBe(false);
    expect(appliedEmojiMuteRevision()).toBeNull();
    expect(currentEmojiMutes()).toEqual([]);

    api().get.mockResolvedValueOnce({ data: document('1', 'new') });
    await loadEmojiMutes();
    expect(appliedEmojiMuteRevision()).toBe('1');
    expect(currentEmojiMutes()).toEqual(document('1', 'new').emoji_mutes);
  });

  it('keeps the Redux rules tied to their applied revision, not just an observed marker', () => {
    const oldRule = document('2', 'old').emoji_mutes;
    const newRule = document('3', 'new').emoji_mutes;
    let state = reducer(undefined, { type: '@@INIT' });

    expect(state.get('phase')).toBe('loading');
    state = reducer(state, { type: EMOJI_MUTES_APPLY, revision: '2', mutes: oldRule });
    expect(state.get('phase')).toBe('ready');
    expect(state.get('appliedRevision')).toBe('2');

    state = reducer(state, { type: EMOJI_MUTES_REVISION, revision: '3' });
    expect(state.get('revision')).toBe('3');
    expect(state.get('phase')).toBe('stale');
    expect(state.get('appliedRevision')).toBe('2');
    const stale = state;

    state = reducer(state, { type: EMOJI_MUTES_APPLY, revision: '2', mutes: [] });
    expect(state).toBe(stale);
    state = reducer(state, { type: EMOJI_MUTES_APPLY, revision: '3', mutes: newRule });
    expect(state.get('phase')).toBe('ready');
    expect(state.get('rules').toJS()).toEqual(newRule);
    expect(state.get('appliedRevision')).toBe('3');

    expect(reducer(state, { type: EMOJI_MUTES_APPLY, revision: '1', mutes: [] })).toBe(state);
    expect(reducer(state, { type: EMOJI_MUTES_FAIL }).get('phase')).toBe('error');
    expect(reducer(state, { type: EMOJI_MUTES_RESET })).toEqual(reducer(undefined, { type: '@@INIT' }));
  });

  it('shows a retryable Redux error instead of spinning on a stale successful GET', async () => {
    api().get.mockResolvedValueOnce({ data: document('4', 'original') });
    await loadEmojiMutes();

    let state = reducer(undefined, { type: EMOJI_MUTES_APPLY, revision: '4', mutes: document('4', 'original').emoji_mutes });
    const actions = [];
    const dispatch = action => {
      if (typeof action === 'function') {
        return action(dispatch, () => ImmutableMap({ emojiMutes: state }));
      }

      actions.push(action);
      state = reducer(state, action);
      return action;
    };

    api().get.mockResolvedValueOnce({ data: document('4', 'stale') });
    await syncEmojiMutes({ changed: { revision: '5' }, bootstrap: true })(dispatch, () => ImmutableMap({ emojiMutes: state }));

    expect(state.get('revision')).toBe('5');
    expect(state.get('appliedRevision')).toBe('4');
    expect(state.get('phase')).toBe('error');
    expect(actions.map(action => action.type)).toContain(EMOJI_MUTES_FAIL);
    expect(emojiMuteDocumentReady()).toBe(false);

    api().get.mockResolvedValueOnce({ data: document('5', 'current') });
    await syncEmojiMutes({ bootstrap: true })(dispatch, () => ImmutableMap({ emojiMutes: state }));
    expect(state.get('phase')).toBe('ready');
    expect(state.get('appliedRevision')).toBe('5');
  });

  it('gates the cached display while reconnect verification is pending', async () => {
    api().get.mockResolvedValueOnce({ data: document('6', 'current') });
    await loadEmojiMutes();

    let state = reducer(undefined, {
      type: EMOJI_MUTES_APPLY,
      revision: '6',
      mutes: document('6', 'current').emoji_mutes,
    });
    const dispatch = action => {
      if (typeof action === 'function') return action(dispatch, () => ImmutableMap({ emojiMutes: state }));
      state = reducer(state, action);
      return action;
    };
    const getState = () => ImmutableMap({ emojiMutes: state });
    const pending = deferred();
    api().get.mockImplementationOnce(() => pending.promise);

    const verifying = syncEmojiMutes({ bootstrap: true, verify: true })(dispatch, getState);
    expect(state.get('phase')).toBe('loading');
    expect(state.get('appliedRevision')).toBe('6');

    pending.resolve({ data: document('6', 'current') });
    await verifying;
    expect(state.get('phase')).toBe('ready');

    // A lagging server is not proof that the current document is valid.
    api().get.mockResolvedValueOnce({ data: document('5', 'old') });
    await expect(syncEmojiMutes({ bootstrap: true, verify: true })(dispatch, getState)).rejects.toThrow('revision');
    expect(state.get('phase')).toBe('error');
  });

  it('only publishes the latest complete document from overlapping sync thunks', async () => {
    const one = deferred();
    const two = deferred();
    api().get.mockImplementationOnce(() => one.promise).mockImplementationOnce(() => two.promise);

    let state = reducer(undefined, { type: '@@INIT' });
    const applied = [];
    const dispatch = action => {
      if (typeof action === 'function') {
        return action(dispatch, () => ImmutableMap({ emojiMutes: state }));
      }
      state = reducer(state, action);
      if (action.type === EMOJI_MUTES_APPLY) {
        applied.push(action.revision);
      }
      return action;
    };
    const getState = () => ImmutableMap({ emojiMutes: state });
    const pendingOne = syncEmojiMutes({ bootstrap: true })(dispatch, getState);
    const pendingTwo = syncEmojiMutes({ bootstrap: true, changed: { revision: '2' } })(dispatch, getState);

    two.resolve({ data: document('2', 'new') });
    await pendingTwo;
    one.resolve({ data: document('1', 'old') });
    await pendingOne;

    expect(applied).toEqual(['2']);
    expect(state.get('appliedRevision')).toBe('2');
    expect(state.get('phase')).toBe('ready');
  });
});
