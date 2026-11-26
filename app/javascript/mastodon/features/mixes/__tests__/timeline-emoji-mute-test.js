/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import { Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_DISABLE, EMOJI_MUTES_IGNORE, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

jest.mock('react-intl', () => {
  const React = require('react');
  const formatMessage = (message, values) => {
    let text = message.defaultMessage || message.id;

    if (values) {
      Object.keys(values).forEach(key => {
        const value = values[key];
        text = text.split(`{${key}}`).join(value === undefined || value === null ? '' : String(value));
      });
    }

    return text;
  };
  const intl = { formatMessage, formatDate: () => '' };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => React.createElement(Component, { ...props, intl: props.intl || intl }),
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('../../../components/status_list', () => {
  const ReactMock = require('react');
  const state = { renders: 0, mounts: 0 };
  global.__mixStatusListRenders = state;

  return function StatusList (props) {
    const mountId = ReactMock.useRef(0);

    if (mountId.current === 0) {
      state.mounts += 1;
      mountId.current = state.mounts;
    }

    state.renders += 1;
    return ReactMock.createElement('div', {
      'data-testid': 'status-list',
      'data-mount': String(mountId.current),
      'data-renders': String(state.renders),
    }, props.prepend);
  };
});

jest.mock('../../../actions/mix_timelines', () => ({
  loadMixTimeline: () => ({ type: 'MIX_TIMELINE_LOAD' }),
  closeMixTimeline: () => ({ type: 'MIX_TIMELINE_CLOSE' }),
  createMixSplit: () => ({ type: 'MIX_SPLIT_CREATE' }),
  destroyMixSplit: () => ({ type: 'MIX_SPLIT_DESTROY' }),
  retryMixSource: () => ({ type: 'MIX_SOURCE_RETRY' }),
  saveMixSplitAnchor: () => ({ type: 'MIX_ANCHOR_SAVE' }),
  clearMixSplitAnchor: () => ({ type: 'MIX_ANCHOR_CLEAR' }),
  mixColumnKey: (columnId, mixId) => columnId || mixId,
}));

jest.mock('../../../actions/mix_streaming', () => ({
  openMixStream: () => ({ type: 'MIX_STREAM_OPEN' }),
  closeMixStream: () => ({ type: 'MIX_STREAM_CLOSE' }),
  pinMixStream: () => ({ type: 'MIX_STREAM_PIN' }),
  reconcileMixSource: () => ({ type: 'MIX_SOURCE_RECONCILE' }),
  revealMixStream: () => ({ type: 'MIX_STREAM_REVEAL' }),
}));

jest.mock('../../../actions/external_feeds', () => ({
  openExternalFeedView: () => ({ type: 'EXTERNAL_FEED_OPEN' }),
  closeExternalFeedView: () => ({ type: 'EXTERNAL_FEED_CLOSE' }),
  resumeExternalFeedViews: () => ({ type: 'EXTERNAL_FEED_RESUME' }),
}));

jest.mock('../../../actions/columns', () => ({
  addColumn: () => ({ type: 'COLUMN_ADD' }),
  removeColumn: () => ({ type: 'COLUMN_REMOVE' }),
  moveColumn: () => ({ type: 'COLUMN_MOVE' }),
  changeColumnParams: () => ({ type: 'COLUMN_PARAMS' }),
}));

jest.mock('../../../actions/settings', () => ({
  changeSetting: () => ({ type: 'SETTING_CHANGE' }),
}));

import { MixTimelinePage } from '../timeline';

const THUMB = '👍';
const FAMILY = '👨‍👩‍👧‍👧';
const COLUMN_TITLE = 'Mix';

const intl = {
  formatMessage: (message, values) => {
    let text = message.defaultMessage || message.id;

    if (values) {
      Object.keys(values).forEach(key => {
        const value = values[key];
        text = text.split(`{${key}}`).join(value === undefined || value === null ? '' : String(value));
      });
    }

    return text;
  },
};

const rule = (emoji, replacement) => ({
  id: `rule-${replacement}`,
  emoji,
  replacement,
  effects: {
    replace_in_text: true,
    hide_reactions: false,
    reject_reactions_to_own_posts: false,
    hide_in_picker: false,
  },
});

const mix = (title) => fromJS({
  id: 'mix-1',
  title,
  version: 1,
  sources: [
    { type: 'home', params: {} },
    { type: 'list', id: '4', title: `Friends ${THUMB}`, params: {} },
  ],
});

const reducer = (state = ImmutableMap(), action) => state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action));

const buildStore = () => createStore(reducer);

const view = {
  statusIds: fromJS([]),
  contextById: {},
  warningsById: {},
  orderGuaranteed: true,
  waiting: false,
  hasMore: false,
  running: false,
  suspended: [],
  errors: [],
  incomplete: [{ key: 'v1|list|4|', label: `Friends ${THUMB}` }],
  restOnly: [{ key: 'v1|account|9|', label: 'v1|account|9|' }],
  degraded: ['v1|home||-'],
};

const renderMix = (store, title = `Desk ${THUMB} ${FAMILY}`, extra = {}) => {
  const privacy = document.createElement('div');
  const mount = document.createElement('div');

  privacy.className = 'emoji-mutes-privacy-portal';
  privacy.appendChild(mount);
  document.body.appendChild(privacy);

  return render(
    <MemoryRouter>
      <Provider store={store}>
        <MixTimelinePage
          dispatch={store.dispatch}
          intl={intl}
          mixId='mix-1'
          mix={mix(title)}
          columnKey='column:mix'
          multiColumn
          columnId='col-mix'
          location={{ key: 'mix-loc', pathname: '/timelines/mixes/mix-1' }}
          view={view}
          {...extra}
        />
      </Provider>
    </MemoryRouter>,
    { container: mount },
  );
};

const headingText = container => container.querySelector('h1 button').textContent;
const region = container => container.querySelector('[role="region"]');

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes, availability: 'enabled' });
  });
};

describe('mix column emoji mute', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
    global.__mixStatusListRenders.renders = 0;
    global.__mixStatusListRenders.mounts = 0;
    document.body.innerHTML = '';
  });

  it('projects the heading, region, user notice, and info label from the same plain source', () => {
    const title = `Desk ${THUMB} ${FAMILY} :blob:`;
    const store = buildStore();
    const guard = createUnverifiedEmojiGuard();
    const during = { region: '', heading: '', notice: '' };

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      during.region = document.querySelector('.emoji-mutes-privacy-portal [role="region"]')?.getAttribute('aria-label') || '';
      during.heading = document.querySelector('.emoji-mutes-privacy-portal h1 button')?.textContent || '';
      during.notice = document.querySelector('.mix-editor__notice span')?.textContent || '';
    });

    const { container } = renderMix(store, title);
    const mountedList = container.querySelector('[data-testid="status-list"]');

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '😺'),
      rule({ kind: 'unicode', native: '😺' }, '[cat]'),
      rule({ kind: 'unicode', native: FAMILY }, '[family]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
    ]);

    expect(headingText(container)).toBe('Desk 😺 [family] :blob:');
    expect(region(container).getAttribute('aria-label')).toBe('Desk 😺 [family] :blob:');
    expect(screen.getByText('Friends 😺 is only partly loaded.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Retry v1|list|4|' }).getAttribute('data-source-key')).toBe('v1|list|4|');
    expect(screen.getByText('v1|account|9| is not live. Refresh to check for new posts.')).toBeTruthy();
    expect(screen.getByText('v1|home||- could not catch up after reconnecting.')).toBeTruthy();
    expect(container.querySelector('[data-testid="status-list"]')).toBe(mountedList);
    expect(container.innerHTML).not.toContain('data-emoji-mute');

    fireEvent.click(screen.getByRole('button', { name: 'Mix information' }));

    expect(screen.getByText('Home')).toBeTruthy();
    expect(screen.getByText('Friends 😺')).toBeTruthy();
    expect(screen.getByText('List')).toBeTruthy();

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      expect(during.region).not.toContain(THUMB);
      expect(during.heading).not.toContain(THUMB);
      expect(during.notice).not.toContain(THUMB);
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        mutes: [
          rule({ kind: 'unicode', native: THUMB }, '😺'),
          rule({ kind: 'unicode', native: '😺' }, '[cat]'),
          rule({ kind: 'unicode', native: FAMILY }, '[family]'),
        ],
        availability: 'enabled',
      });
      expect(during.region).toBe('Desk 😺 [family] :blob:');
      expect(during.heading).toBe('Desk 😺 [family] :blob:');
      expect(during.notice).toBe('Friends 😺 is only partly loaded.');
      expect(during.region).not.toContain('[cat]');
      expect(during.notice).not.toContain('[cat]');
    });
  });

  it('uses the Mix column name when a title projects to nothing', () => {
    const store = buildStore();
    const { container } = renderMix(store, THUMB);

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '   ')]);

    expect(region(container).getAttribute('aria-label')).toBe(COLUMN_TITLE);
    expect(headingText(container)).toBe('   ');
    expect(container.querySelector('h1 > button').getAttribute('aria-label')).toBe(COLUMN_TITLE);
    expect(container.querySelector('h1 > button').getAttribute('aria-label')).not.toContain(THUMB);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(region(container).getAttribute('aria-label')).toBe(THUMB);
    expect(headingText(container)).toBe(THUMB);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    expect(headingText(container)).toBe(THUMB);
    expect(region(container).getAttribute('aria-label')).toBe(THUMB);
  });

  it('follows a renamed mix without keeping the previous emoji', () => {
    const store = buildStore();
    const { rerender, container } = renderMix(store, `Desk ${THUMB}`);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[old]'),
      rule({ kind: 'unicode', native: '✨' }, '[new]'),
    ]);

    expect(headingText(container)).toBe('Desk [old]');

    rerender(
      <MemoryRouter>
        <Provider store={store}>
          <MixTimelinePage
            dispatch={store.dispatch}
            intl={intl}
            mixId='mix-1'
            mix={mix('Night ✨')}
            columnKey='column:mix'
            multiColumn
            columnId='col-mix'
            location={{ key: 'mix-loc', pathname: '/timelines/mixes/mix-1' }}
            view={view}
          />
        </Provider>
      </MemoryRouter>,
    );

    expect(headingText(container)).toBe('Night [new]');
    expect(region(container).getAttribute('aria-label')).toBe('Night [new]');
    expect(headingText(container)).not.toContain(THUMB);
    expect(region(container).getAttribute('aria-label')).not.toContain('[old]');
  });

  it('projects an account display name from its own HTML and leaves saved titles literal', () => {
    const localImg = (id) => (
      `<img draggable="false" class="emojione custom-emoji" alt=":blob:" title="blob" src="https://cdn.example/${id}.svg" data-shortcode="blob" data-domain="" data-emoji-id="${id}">`
    );
    const remoteImg = (domain) => (
      `<img draggable="false" class="emojione custom-emoji" alt=":blob:" title="blob" src="https://cdn.example/${domain}/blob.svg" data-shortcode="blob" data-domain="${domain}">`
    );
    const unicodeImg = (native) => (
      `<img draggable="false" class="emojione" alt="${native}" title="${native}" src="/emoji/${encodeURIComponent(native)}.svg">`
    );
    const account = (id, fields) => fromJS({
      id,
      acct: `${id}@example.com`,
      username: id,
      ...fields,
    });
    const sources = [
      { type: 'account', id: '9', params: {} },
      { type: 'account', id: '8', params: {} },
      { type: 'account', id: '5', params: {} },
      { type: 'account', id: '7', title: ':blob:', params: {} },
      { type: 'account', id: '6', params: {} },
    ];
    const accountsFor = (ninth) => fromJS({
      9: account('9', ninth),
      8: account('8', { display_name: ':blob:', display_name_html: remoteImg('a.test') }),
      5: account('5', { display_name: ':blob:', display_name_html: localImg('12') }),
      7: account('7', { display_name: ':blob:', display_name_html: localImg('11') }),
      6: account('6', { display_name: '', display_name_html: localImg('10'), acct: 'plain-user', username: 'plain-user' }),
    });
    const mixWithAccounts = fromJS({
      id: 'mix-1',
      title: 'Desk',
      version: 1,
      sources,
    });
    const store = buildStore();
    const guard = createUnverifiedEmojiGuard();
    const during = { labels: '' };

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      during.labels = Array.from(document.querySelectorAll('.mix-info__label')).map(node => node.textContent).join('|');
    });

    const rendered = renderMix(store, 'Desk', {
      mix: mixWithAccounts,
      accounts: accountsFor({ display_name: ':blob:', display_name_html: localImg('10') }),
    });

    fireEvent.click(screen.getByRole('button', { name: 'Mix information' }));

    const labels = () => Array.from(document.querySelectorAll('.mix-info__label')).map(node => node.textContent);

    expect(labels()).toEqual([':blob:', ':blob:', ':blob:', ':blob:', 'plain-user']);

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '😺'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[saved-html]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '12', shortcode: 'blob' }, '[other]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[remote]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'b.test', shortcode: 'blob' }, '[elsewhere]'),
      rule({ kind: 'unicode', native: '😺' }, '[cat]'),
      rule({ kind: 'unicode', native: '✨' }, '[star]'),
    ]);

    expect(labels()).toEqual(['😺', '[remote]', '[other]', ':blob:', 'plain-user']);
    expect(document.querySelector('.mix-info__label img')).toBeNull();
    expect(rendered.container.innerHTML).not.toContain('data-emoji-mute');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      expect(during.labels.split('|')[0]).not.toContain(':blob:');
      expect(during.labels).not.toContain('👍');
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [
          rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '😺'),
          rule({ kind: 'custom', scope: 'local', custom_emoji_id: '12', shortcode: 'blob' }, '[other]'),
          rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[remote]'),
          rule({ kind: 'unicode', native: '😺' }, '[cat]'),
          rule({ kind: 'unicode', native: '✨' }, '[star]'),
        ],
      });
      expect(during.labels.split('|')[0]).toBe('😺');
      expect(during.labels).not.toContain('[cat]');
      expect(during.labels).toContain(':blob:');
      expect(during.labels).toContain('plain-user');
    });

    expect(labels()[0]).toBe('😺');

    rendered.rerender(
      <MemoryRouter>
        <Provider store={store}>
          <MixTimelinePage
            dispatch={store.dispatch}
            intl={intl}
            mixId='mix-1'
            mix={mixWithAccounts}
            accounts={accountsFor({ display_name: '✨', display_name_html: unicodeImg('✨') })}
            columnKey='column:mix'
            multiColumn
            columnId='col-mix'
            location={{ key: 'mix-loc', pathname: '/timelines/mixes/mix-1' }}
            view={view}
          />
        </Provider>
      </MemoryRouter>,
    );

    expect(labels()[0]).toBe('[star]');
    expect(labels().join('|')).not.toContain('😺');
    expect(labels()[3]).toBe(':blob:');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(labels()[0]).toBe('✨');
    expect(labels()[1]).toBe(':blob:');
    expect(labels()[3]).toBe(':blob:');
    expect(labels()[4]).toBe('plain-user');
  });
});
