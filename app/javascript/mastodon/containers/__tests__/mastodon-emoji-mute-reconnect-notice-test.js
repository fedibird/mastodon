/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
import fs from 'fs';
import path from 'path';
import React from 'react';

const gets = [];
const streams = [];
const mockHarness = { dispatch: null, getState: null };

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
};

const documentFor = revision => ({
  data: { revision, enabled: true, explicit: true, emoji_mutes: [] },
});

const serverError = () => Object.assign(new Error('server'), { response: { status: 500 } });

jest.mock('mastodon/initial_state_data', () => ({
  meta: {
    me: '1',
    access_token: 'token',
    emoji_mute_enabled: true,
    emoji_mute_enabled_known: true,
    emoji_mute_enabled_explicit: true,
    emoji_mute_modal: true,
  },
}));

jest.mock('mastodon/api', () => {
  const get = jest.fn();
  const post = jest.fn(() => Promise.resolve({ data: {} }));
  return { __esModule: true, default: jest.fn(() => ({ get, post })) };
});

jest.mock('mastodon/stream', () => ({
  connectStream: (channelName, params, factory) => (dispatch, getState) => {
    streams.push({ channelName, params, handlers: factory(dispatch, getState) });
    return () => {};
  },
}));

jest.mock('mastodon/actions/timelines', () => ({
  updateTimeline: () => ({ type: 'TEST_TIMELINE' }),
  deleteFromTimelines: () => ({ type: 'TEST_TIMELINE' }),
  expireFromTimelines: () => ({ type: 'TEST_TIMELINE' }),
  expandHomeTimeline: () => ({ type: 'TEST_TIMELINE' }),
  expandListTimeline: () => ({ type: 'TEST_TIMELINE' }),
  connectTimeline: () => ({ type: 'TEST_TIMELINE' }),
  disconnectTimeline: () => ({ type: 'TEST_TIMELINE' }),
}));

jest.mock('mastodon/actions/filters', () => ({
  scheduleFiltersRefresh: () => ({ type: 'TEST_FILTERS' }),
}));

jest.mock('mastodon/filter_reconciliation/scheduler', () => ({
  retryFilterReconciliation: () => ({ type: 'TEST_FILTERS' }),
}));

jest.mock('mastodon/actions/external_boosts', () => ({
  receiveExternalLinkBoostChanged: () => ({ type: 'TEST_BOOST' }),
  reconcileHeldExternalBoosts: () => ({ type: 'TEST_BOOST' }),
}));

jest.mock('mastodon/actions/external_feeds', () => ({
  bindExternalFeedVisibility: () => ({ type: 'TEST_FEED' }),
  noteExternalStatusStream: () => {},
  receiveExternalFeedChanged: () => ({ type: 'TEST_FEED' }),
  reconcileExternalFeedView: () => ({ type: 'TEST_FEED' }),
  reconcileOpenExternalViews: () => ({ type: 'TEST_FEED' }),
  refreshExternalFeedCapability: () => ({ type: 'TEST_FEED' }),
  resumeExternalFeedViews: () => ({ type: 'TEST_FEED' }),
}));

jest.mock('mastodon/store/configureStore', () => {
  const ImmutableMapLocal = require('immutable').Map;
  const emojiMutesReducer = require('mastodon/reducers/emoji_mutes').default;
  const subscribers = new Set();
  let state = ImmutableMapLocal({
    emojiMutes: emojiMutesReducer(undefined, { type: '@@INIT' }),
    meta: ImmutableMapLocal({ me: '1', access_token: 'token' }),
  });
  const reduce = action => state.set('emojiMutes', emojiMutesReducer(state.get('emojiMutes'), action));
  const dispatch = action => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    state = reduce(action);
    subscribers.forEach(listener => listener());
    return action;
  };
  mockHarness.dispatch = dispatch;
  mockHarness.getState = () => state;
  return {
    __esModule: true,
    default: jest.fn(() => ({
      dispatch,
      getState: () => state,
      subscribe: listener => {
        subscribers.add(listener);
        return () => subscribers.delete(listener);
      },
    })),
  };
});

jest.mock('mastodon/actions/store', () => ({ hydrateStore: () => ({ type: 'TEST_HYDRATE' }) }));
jest.mock('mastodon/actions/circles', () => ({
  fetchCircles: () => ({ type: 'TEST_CIRCLES' }),
  prefetchCircles: () => ({ type: 'TEST_CIRCLES' }),
}));
jest.mock('mastodon/actions/custom_emojis', () => ({ ensureCustomEmojis: () => ({ type: 'TEST_EMOJIS' }) }));
jest.mock('mastodon/features/emoji/emoji_picker_preferences', () => ({ preloadEmojiPickersIfNeeded: jest.fn() }));
jest.mock('mastodon/locales', () => ({ getLocale: () => ({ localeData: [], messages: {} }) }));
jest.mock('react-intl', () => {
  const ReactMock = require('react');
  return {
    IntlProvider: ({ children }) => <ReactMock.Fragment>{children}</ReactMock.Fragment>,
    FormattedMessage: ({ defaultMessage }) => <span>{defaultMessage}</span>,
    defineMessages: messages => messages,
    addLocaleData: jest.fn(),
  };
});
jest.mock('react-router-dom', () => ({
  BrowserRouter: ({ children }) => <div>{children}</div>,
  Route: ({ component: Component }) => <Component />,
}));
jest.mock('react-router-scroll-4', () => ({ ScrollContext: ({ children }) => <div>{children}</div> }));
jest.mock('mastodon/features/ui', () => {
  const ReactMock = require('react');
  const Notice = require('mastodon/components/emoji_mute_load_notice').default;

  return class MockUI extends ReactMock.Component {

    render() {
      const surface = global.__emojiMuteFocusSurface;
      let controls = (
        <ReactMock.Fragment>
          <textarea className='autosuggest-textarea__textarea' data-testid='composer' />
          <input className='search__input' data-testid='search-field' />
          <button type='button' data-testid='elsewhere'>Elsewhere</button>
        </ReactMock.Fragment>
      );

      if (surface === 'columns') {
        controls = (
          <ReactMock.Fragment>
            <a className='column-link' href='/timelines/home' data-testid='column-home'>Home</a>
            <button type='button' data-testid='elsewhere'>Elsewhere</button>
          </ReactMock.Fragment>
        );
      }

      if (surface === 'timeline') {
        controls = (
          <ReactMock.Fragment>
            <h1 className='column-header' hidden>
              <button type='button' data-testid='hidden-heading'>Hidden</button>
            </h1>
            <h1 className='column-header'>
              <button type='button' data-testid='column-heading'>Home</button>
            </h1>
            <button type='button' data-testid='elsewhere'>Elsewhere</button>
          </ReactMock.Fragment>
        );
      }

      return (
        <div data-testid='webui'>
          {controls}
          <Notice key={global.__emojiMuteNoticeMount || 'notice'} placement={surface ? 'overlay' : 'compose-panel'} />
        </div>
      );
    }

  };
});
jest.mock('mastodon/components/error_boundary', () => ({ children }) => <div>{children}</div>);
jest.mock('mastodon/features/embedded_rails_settings/navigation', () => ({
  settingsReturnScroll: () => null,
  settleSettingsReturnScroll: jest.fn(),
}));

import api from 'mastodon/api';
import { applyRemoteEmojiMutePreference, emojiMuteSyncInFlight } from 'mastodon/actions/emoji_mutes';
import { emojiMuteTextIndexFromState, replaceEmojiInDisplayHtml } from 'mastodon/features/emoji/emoji_mute_text';
import { beginEmojiMutePreferenceRead, emojiMutePreferenceGeneration, resetEmojiMuteStoreForTests } from 'mastodon/features/emoji/emoji_mute_store';

const Mastodon = require('../mastodon').default;

const clock = { now: 1_000_000 };
const notice = view => view.container.querySelector('.emoji-mute-load-notice');
const userStream = () => streams.find(entry => entry.channelName === 'user').handlers;
const flush = async () => {
  for (let step = 0; step < 8; step += 1) {
    await Promise.resolve();
  }
};
const emojiSample = '<p><img class="emojione" alt="👍" src="/emoji/1f44d.svg"></p><a aria-label="👍" href="https://example.test/keep">link</a>';

const projectedEmoji = () => replaceEmojiInDisplayHtml(emojiSample, emojiMuteTextIndexFromState(mockHarness.getState()));

describe('emoji mute failure notice during streaming resync', () => {
  beforeEach(() => {
    clock.now = 1_000_000;
    jest.spyOn(Date, 'now').mockImplementation(() => clock.now);
    gets.length = 0;
    streams.length = 0;
    global.__emojiMuteNoticeMount = 'notice';
    resetEmojiMuteStoreForTests();
    api().get.mockReset();
    api().get.mockImplementation(url => {
      if (url === '/api/v1/fedibird/emoji_mutes') {
        const pending = deferred();
        gets.push(pending);
        return pending.promise;
      }

      return Promise.resolve({ data: [] });
    });
  });

  afterEach(() => {
    Date.now.mockRestore();
    delete global.__emojiMuteNoticeMount;
    delete global.__emojiMuteFocusSurface;
  });

  const rejectGet = async pending => {
    await act(async () => {
      pending.reject(serverError());
      try {
        await pending.promise;
      } catch (error) {
        // The bootstrap or stream caller owns the rejection.
      }
      await flush();
    });
  };

  it('keeps the error card visible when streaming connect and reconnect repeat a 500', async () => {
    const view = render(<Mastodon locale='en' />);

    expect(view.getByTestId('webui')).not.toBeNull();
    expect(gets).toHaveLength(1);
    expect(notice(view)).toBeNull();
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');

    act(() => {
      userStream().onConnect();
    });

    expect(gets).toHaveLength(1);
    expect(notice(view)).toBeNull();

    await rejectGet(gets[0]);

    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).toBe('error');
    expect(mockHarness.getState().getIn(['emojiMutes', 'failure'])).toBe('unavailable');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');
    expect(projectedEmoji()).not.toContain('/emoji/1f44d.svg');
    expect(projectedEmoji()).not.toContain('👍');
    expect(projectedEmoji()).toContain('aria-label="◻"');
    expect(projectedEmoji()).toContain('href="https://example.test/keep"');

    let followed;
    act(() => {
      followed = userStream().onConnect();
    });

    expect(gets).toHaveLength(2);
    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(notice(view).getAttribute('data-rechecking')).toBe('true');
    expect(notice(view).querySelector('.emoji-mute-load-notice__close')).toBeNull();
    expect(notice(view).querySelector('.emoji-mute-load-notice__action--primary')).toBeDisabled();
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');
    expect(projectedEmoji()).not.toContain('👍');

    const duringFollowUp = gets.length;
    fireEvent.click(view.getByText('Try again'));
    expect(gets).toHaveLength(duringFollowUp);

    act(() => {
      userStream().onDisconnect();
      userStream().onConnect();
    });

    expect(gets).toHaveLength(3);
    expect(notice(view)).not.toBeNull();

    await rejectGet(gets[1]);

    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(view.container.textContent).not.toContain('Reload and sign in');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');

    await act(async () => {
      gets[2].reject(serverError());
      try {
        await followed;
      } catch (error) {
        // The first follow-up is superseded by the reconnect.
      }
      await flush();
    });

    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).toBe('error');
    expect(mockHarness.getState().getIn(['emojiMutes', 'failure'])).toBe('unavailable');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');

    let recovered;
    act(() => {
      userStream().onDisconnect();
      recovered = userStream().onConnect();
    });

    expect(notice(view)).not.toBeNull();

    await act(async () => {
      gets[3].resolve(documentFor('4'));
      await recovered;
      await flush();
    });

    expect(notice(view)).toBeNull();
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).toBe('ready');
    expect(mockHarness.getState().getIn(['emojiMutes', 'failure'])).toBeNull();
    expect(mockHarness.getState().getIn(['emojiMutes', 'appliedRevision'])).toBe('4');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('apply');
    view.unmount();
  });

  it('drops the tab wording and lets an ignored card be closed without changing mute state', async () => {
    const en = JSON.parse(fs.readFileSync(path.join(__dirname, '../../locales/en.json'), 'utf8'));
    const ja = JSON.parse(fs.readFileSync(path.join(__dirname, '../../locales/ja.json'), 'utf8'));

    expect(en['emoji_mutes.notice_ignored_close']).toBe('Close this notice');
    expect(ja['emoji_mutes.notice_ignored_close']).toBe('通知を閉じる');
    expect(en['emoji_mutes.notice_ignored_title']).toBe('Emoji muting is temporarily ignored');
    expect(en['emoji_mutes.bootstrap_ignored']).toBe('Emoji muting is not applied. Muted emoji are visible too. Reloading fetches the settings again.');
    expect(en['emoji_mutes.notice_ignored_title']).not.toContain('this tab');
    expect(en['emoji_mutes.bootstrap_ignored']).not.toContain('this tab');
    expect(ja['emoji_mutes.notice_ignored_title']).toBe('絵文字ミュートを一時的に無視しています');
    expect(ja['emoji_mutes.bootstrap_ignored']).toBe('絵文字ミュートを適用していません。ミュートした絵文字も表示されます。再読み込みすると設定の取得をやり直します。');
    expect(ja['emoji_mutes.notice_ignored_title']).not.toContain('このタブ');
    expect(ja['emoji_mutes.bootstrap_ignored']).not.toContain('このタブ');
    expect(en['emoji_mutes.external']).toContain('another tab');
    expect(ja['emoji_mutes.external']).toContain('別のタブ');

    const view = render(<Mastodon locale='en' />);
    await rejectGet(gets[0]);
    expect(notice(view).querySelector('.emoji-mute-load-notice__close')).toBeNull();
    const getsBeforeIgnore = gets.length;

    await act(async () => {
      fireEvent.click(view.getByText('Ignore this time'));
      await flush();
    });

    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Emoji muting is temporarily ignored');
    expect(notice(view).textContent).toContain('Emoji muting is not applied. Muted emoji are visible too. Reloading fetches the settings again.');
    expect(notice(view).textContent).not.toContain('this tab');
    expect(mockHarness.getState().getIn(['emojiMutes', 'availability'])).toBe('temporary_ignore');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('show');
    expect(projectedEmoji()).toContain('👍');
    expect(projectedEmoji()).toContain('aria-label="👍"');
    expect(gets).toHaveLength(getsBeforeIgnore);

    const close = notice(view).querySelector('.emoji-mute-load-notice__close');
    expect(close).not.toBeNull();
    expect(close.tagName).toBe('BUTTON');
    expect(close.getAttribute('type')).toBe('button');
    expect(close.textContent).toContain('Close this notice');

    fireEvent.click(close);

    expect(notice(view)).toBeNull();
    expect(mockHarness.getState().getIn(['emojiMutes', 'availability'])).toBe('temporary_ignore');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('show');
    expect(gets).toHaveLength(getsBeforeIgnore);
    expect(projectedEmoji()).toContain('👍');

    act(() => {
      userStream().onConnect();
    });

    expect(gets).toHaveLength(getsBeforeIgnore);
    expect(notice(view)).toBeNull();

    global.__emojiMuteNoticeMount = 'remounted';
    view.rerender(<Mastodon locale='ja' />);

    expect(notice(view)).toBeNull();
    expect(mockHarness.getState().getIn(['emojiMutes', 'availability'])).toBe('temporary_ignore');
    expect(sessionStorage.getItem('fedibird:emoji-mute-notice-closed')).toBeNull();

    view.unmount();
    const reloaded = render(<Mastodon locale='en' />);
    expect(gets.length).toBeGreaterThan(getsBeforeIgnore);
    expect(notice(reloaded)).toBeNull();
    await rejectGet(gets[gets.length - 1]);
    expect(notice(reloaded)).not.toBeNull();
    expect(notice(reloaded).textContent).toContain('Couldn\'t load emoji mutes');
    expect(notice(reloaded).querySelector('.emoji-mute-load-notice__close')).toBeNull();
    reloaded.unmount();
  });

  it('reenables retry when the newest sync ends on a stale preference snapshot', async () => {
    const view = render(<Mastodon locale='en' />);
    await rejectGet(gets[0]);
    const retry = () => notice(view).querySelector('.emoji-mute-load-notice__action--primary');

    expect(retry().disabled).toBe(false);

    act(() => {
      userStream().onConnect();
    });

    expect(gets).toHaveLength(2);
    expect(notice(view).getAttribute('data-rechecking')).toBe('true');
    expect(retry().disabled).toBe(true);
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');

    const older = gets[1];
    act(() => {
      userStream().onDisconnect();
      userStream().onConnect();
    });

    expect(gets).toHaveLength(3);
    expect(retry().disabled).toBe(true);
    const generationBeforePreference = emojiMutePreferenceGeneration();

    let preferenceRead;
    await act(async () => {
      preferenceRead = mockHarness.dispatch(applyRemoteEmojiMutePreference());
      await flush();
    });

    expect(emojiMutePreferenceGeneration()).toBeGreaterThan(generationBeforePreference);
    expect(retry().disabled).toBe(true);
    expect(emojiMuteSyncInFlight()).toBe(true);

    await act(async () => {
      older.resolve({
        data: { revision: '1', enabled: false, explicit: true, emoji_mutes: [] },
      });
      await older.promise;
      await flush();
    });

    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(retry().disabled).toBe(true);
    expect(emojiMuteSyncInFlight()).toBe(true);
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).not.toBe('ready');
    expect(mockHarness.getState().getIn(['emojiMutes', 'availability'])).not.toBe('disabled');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');
    expect(projectedEmoji()).not.toContain('👍');

    await act(async () => {
      gets[2].resolve({
        data: { revision: '1', enabled: false, explicit: true, emoji_mutes: [] },
      });
      await flush();
      await preferenceRead;
    });

    expect(notice(view)).not.toBeNull();
    expect(notice(view).textContent).toContain('Couldn\'t load emoji mutes');
    expect(notice(view).getAttribute('data-rechecking')).toBe('false');
    expect(retry().disabled).toBe(false);
    expect(emojiMuteSyncInFlight()).toBe(false);
    expect(mockHarness.getState().getIn(['emojiMutes', 'phase'])).not.toBe('ready');
    expect(mockHarness.getState().getIn(['emojiMutes', 'availability'])).not.toBe('disabled');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');
    expect(projectedEmoji()).not.toContain('👍');
    expect(projectedEmoji()).toContain('aria-label="◻"');

    beginEmojiMutePreferenceRead();
    clock.now += 1000;
    const started = gets.length;
    fireEvent.click(retry());
    expect(gets.length).toBe(started + 1);
    expect(retry().disabled).toBe(true);
    view.unmount();
  });

  const ignoredNotice = async () => {
    const view = render(<Mastodon locale='en' />);
    await rejectGet(gets[gets.length - 1]);
    await act(async () => {
      fireEvent.click(view.getByText('Ignore this time'));
      await flush();
    });
    return view;
  };

  it('moves focus to the composer after a focused close, and leaves another control focused', async () => {
    const view = render(<Mastodon locale='en' />);
    expect(gets).toHaveLength(1);
    await rejectGet(gets[0]);
    expect(notice(view)).not.toBeNull();
    await act(async () => {
      fireEvent.click(view.getByText('Ignore this time'));
      await flush();
    });
    const close = notice(view).querySelector('.emoji-mute-load-notice__close');
    const composer = view.getByTestId('composer');

    close.focus();
    expect(document.activeElement).toBe(close);
    fireEvent.keyDown(close, { key: 'Enter', code: 'Enter' });
    fireEvent.click(close);

    expect(notice(view)).toBeNull();
    expect(document.activeElement).toBe(composer);
    expect(mockHarness.getState().getIn(['emojiMutes', 'availability'])).toBe('temporary_ignore');
    view.unmount();

    const again = await ignoredNotice();
    const elsewhere = again.getByTestId('elsewhere');
    elsewhere.focus();
    fireEvent.click(notice(again).querySelector('.emoji-mute-load-notice__close'));

    expect(notice(again)).toBeNull();
    expect(document.activeElement).toBe(elsewhere);
    again.unmount();
  });

  it('moves focus to a column link when the fallback has no composer or search', async () => {
    global.__emojiMuteFocusSurface = 'columns';
    const view = render(<Mastodon locale='en' />);
    await rejectGet(gets[gets.length - 1]);
    await act(async () => {
      fireEvent.click(view.getByText('Ignore this time'));
      await flush();
    });
    const close = notice(view).querySelector('.emoji-mute-load-notice__close');
    const home = view.getByTestId('column-home');

    expect(notice(view).getAttribute('data-placement')).toBe('overlay');
    expect(view.queryByTestId('composer')).toBeNull();
    expect(view.queryByTestId('search-field')).toBeNull();
    close.focus();
    fireEvent.keyDown(close, { key: 'Enter', code: 'Enter' });
    fireEvent.click(close);

    expect(notice(view)).toBeNull();
    expect(document.activeElement).toBe(home);
    expect(mockHarness.getState().getIn(['emojiMutes', 'availability'])).toBe('temporary_ignore');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('show');
    view.unmount();

    global.__emojiMuteFocusSurface = 'columns';
    global.__emojiMuteNoticeMount = 'columns-again';
    const again = render(<Mastodon locale='en' />);
    await rejectGet(gets[gets.length - 1]);
    await act(async () => {
      fireEvent.click(again.getByText('Ignore this time'));
      await flush();
    });
    const elsewhere = again.getByTestId('elsewhere');
    elsewhere.focus();
    fireEvent.click(notice(again).querySelector('.emoji-mute-load-notice__close'));

    expect(notice(again)).toBeNull();
    expect(document.activeElement).toBe(elsewhere);
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('show');
    again.unmount();
  });

  it('moves focus to the timeline heading when no composer, search, or column link exists', async () => {
    global.__emojiMuteFocusSurface = 'timeline';
    const view = render(<Mastodon locale='en' />);
    await rejectGet(gets[gets.length - 1]);
    await act(async () => {
      fireEvent.click(view.getByText('Ignore this time'));
      await flush();
    });
    const close = notice(view).querySelector('.emoji-mute-load-notice__close');
    const heading = view.getByTestId('column-heading');

    expect(view.queryByTestId('composer')).toBeNull();
    expect(view.queryByTestId('search-field')).toBeNull();
    expect(view.container.querySelector('a.column-link')).toBeNull();
    expect(heading.className).toBe('');
    close.focus();
    fireEvent.keyDown(close, { key: 'Enter', code: 'Enter' });
    fireEvent.click(close);

    expect(notice(view)).toBeNull();
    expect(document.activeElement).toBe(heading);
    expect(document.activeElement).not.toBe(view.getByTestId('hidden-heading'));
    expect(mockHarness.getState().getIn(['emojiMutes', 'availability'])).toBe('temporary_ignore');
    expect(mockHarness.getState().getIn(['emojiMutes', 'display'])).toBe('show');
    view.unmount();

    global.__emojiMuteFocusSurface = 'timeline';
    global.__emojiMuteNoticeMount = 'timeline-again';
    const again = render(<Mastodon locale='en' />);
    await rejectGet(gets[gets.length - 1]);
    await act(async () => {
      fireEvent.click(again.getByText('Ignore this time'));
      await flush();
    });
    const elsewhere = again.getByTestId('elsewhere');
    elsewhere.focus();
    fireEvent.click(notice(again).querySelector('.emoji-mute-load-notice__close'));

    expect(notice(again)).toBeNull();
    expect(document.activeElement).toBe(elsewhere);
    again.unmount();
  });
});
