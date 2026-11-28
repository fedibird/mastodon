/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_ENABLE, EMOJI_MUTES_IGNORE, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import { MixList } from '../index';

const THUMB = '👍';
const CAT = '😺';
const PLACEHOLDER = '\u25FB';

const unicodeImg = native => (
  `<img draggable="false" class="emojione" alt="${native}" title="${native}" src="/emoji/${encodeURIComponent(native)}.svg">`
);

const localImg = (id, shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/${id}.svg" data-shortcode="${shortcode}" data-domain="" data-emoji-id="${id}">`
);

const remoteImg = (domain, shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/${domain}/${shortcode}.svg" data-shortcode="${shortcode}" data-domain="${domain}">`
);

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

const intl = { formatMessage: message => message.defaultMessage || message.id };

const renderList = (store, props, container) => render(
  <Provider store={store}>
    <MemoryRouter>
      <MixList intl={intl} mixes={fromJS([])} {...props} />
    </MemoryRouter>
  </Provider>,
  container ? { container } : undefined,
);

const mountGuarded = (store, props) => {
  const guard = createUnverifiedEmojiGuard();
  const during = { title: '', name: '', description: '' };

  store.subscribe(() => guard(store.getState()));
  store.subscribe(() => {
    const link = document.querySelector('.mix-list__link');
    const describedBy = link ? link.getAttribute('aria-describedby') : '';
    const description = describedBy ? document.getElementById(describedBy) : null;

    during.title = link?.querySelector('.mix-list__title')?.textContent || '';
    during.name = link?.getAttribute('aria-label') || '';
    during.description = description?.textContent || '';
  });

  const privacy = document.createElement('div');
  const mount = document.createElement('div');

  privacy.className = 'emoji-mutes-privacy-portal';
  privacy.appendChild(mount);
  document.body.appendChild(privacy);

  const view = renderList(store, props, mount);

  return { during, container: view.container };
};

const buildStore = () => createStore(
  combineReducers({ emojiMutes }),
  applyMiddleware(thunk),
);

describe('mix list emoji mute', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  afterEach(() => {
    document.body.innerHTML = '';
  });

  const identityMix = () => ({
    mixes: fromJS([{
      id: 'mix-1',
      title: `Desk ${THUMB}`,
      version: 1,
      sources: [
        { type: 'home', params: {} },
        { type: 'group', id: '8', title: 'News :blob:', params: {} },
        { type: 'account', id: '9', params: {} },
        { type: 'account', id: '10', title: 'Saved Ada', params: {} },
      ],
    }]),
    lists: fromJS({}),
    accounts: fromJS({
      9: {
        id: '9',
        display_name: `Ada ${THUMB}`,
        display_name_html: `Ada ${unicodeImg(THUMB)} ${localImg('10')} ${remoteImg('a.test')} ${remoteImg('b.test')}`,
        acct: 'ada@example.com',
      },
      10: {
        id: '10',
        title: 'Saved Ada',
        display_name: `Other ${THUMB}`,
        display_name_html: `Other ${unicodeImg(THUMB)} ${localImg('10')}`,
        acct: 'other@example.com',
      },
    }),
  });

  it('keeps projected source names in the link description', () => {
    const store = buildStore();
    const described = 'Ada 😺 [local] [remote-a] :blob:';
    const { during, container } = mountGuarded(store, identityMix());
    const applied = [
      rule({ kind: 'unicode', native: THUMB }, CAT),
      rule({ kind: 'unicode', native: CAT }, '[cat]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[remote-a]'),
    ];

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_APPLY, revision: '2', availability: 'enabled', mutes: applied });
    });

    const open = screen.getByRole('link', { name: `Desk ${CAT}` });
    const sources = document.getElementById('mix-list-sources-mix-1');
    const labels = Array.from(container.querySelectorAll('.mix-list__source-label')).map(node => node.textContent);

    expect(open.getAttribute('href')).toBe('/timelines/mixes/mix-1');
    expect(open.getAttribute('aria-label')).toBe(`Desk ${CAT}`);
    expect(open.getAttribute('aria-describedby')).toBe('mix-list-sources-mix-1');
    expect(open.getAttribute('aria-describedby')).not.toContain(THUMB);
    expect(open.getAttribute('aria-describedby')).not.toContain(CAT);
    expect(sources.textContent).toContain('Home');
    expect(sources.textContent).toContain('News :blob:');
    expect(sources.textContent).toContain(described);
    expect(sources.textContent).toContain('Saved Ada');
    expect(sources.textContent.indexOf('Home')).toBeLessThan(sources.textContent.indexOf('News :blob:'));
    expect(sources.textContent.indexOf('News :blob:')).toBeLessThan(sources.textContent.indexOf(described));
    expect(sources.textContent.indexOf(described)).toBeLessThan(sources.textContent.indexOf('Saved Ada'));
    expect(labels).toEqual(['Home', 'News :blob:', described, 'Saved Ada']);
    expect(sources.innerHTML).not.toContain(THUMB);
    expect(sources.innerHTML).not.toContain('[cat]');
    expect(sources.innerHTML).not.toContain('data-emoji-id');
    expect(screen.getByRole('link', { name: 'Mix settings' }).getAttribute('href')).toBe('/mixes/mix-1/edit');
    expect(screen.getByRole('link', { name: 'Mix settings' }).hasAttribute('aria-describedby')).toBe(false);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      expect(during.title).toBe(`Desk ${PLACEHOLDER}`);
      expect(during.name).toBe(`Desk ${PLACEHOLDER}`);
      expect(during.description).toContain(`Ada ${PLACEHOLDER}`);
      expect(during.description).toContain('News :blob:');
      expect(during.description).toContain('Saved Ada');
      expect(during.title).not.toContain(THUMB);
      expect(during.description).not.toContain(THUMB);
      store.dispatch({ type: EMOJI_MUTES_APPLY, revision: '3', availability: 'enabled', mutes: applied });
      expect(during.title).toBe(`Desk ${CAT}`);
      expect(during.name).toBe(`Desk ${CAT}`);
      expect(during.description).toContain(described);
      expect(during.description).not.toContain('[cat]');
      expect(during.description).toContain('News :blob:');
    });

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(container.querySelector('.mix-list__title').textContent).toBe(`Desk ${THUMB}`);
    expect(container.querySelector('.mix-list__link').getAttribute('aria-label')).toBe(`Desk ${THUMB}`);
    expect(document.getElementById('mix-list-sources-mix-1').textContent).toContain(`Ada ${THUMB}`);
    expect(document.getElementById('mix-list-sources-mix-1').textContent).toContain('News :blob:');
    expect(document.getElementById('mix-list-sources-mix-1').textContent).toContain('Saved Ada');
  });

  it('uses the mix column name when the stored title projects to nothing and still describes the sources', () => {
    const store = buildStore();
    const { during, container } = mountGuarded(store, {
      mixes: fromJS([{
        id: 'mix-1',
        title: THUMB,
        version: 1,
        sources: [
          { type: 'group', id: '8', title: 'Newsroom', params: {} },
          { type: 'account', id: '9', params: {} },
        ],
      }]),
      accounts: fromJS({
        9: {
          id: '9',
          display_name: `Ada ${THUMB}`,
          display_name_html: `Ada ${unicodeImg(THUMB)}`,
          acct: 'ada@example.com',
        },
      }),
    });
    const blank = [rule({ kind: 'unicode', native: THUMB }, '')];

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_ENABLE });
      expect(during.name).toContain(PLACEHOLDER);
      expect(during.name).not.toContain(THUMB);
      expect(during.description).toContain('Newsroom');
      expect(during.description).toContain(PLACEHOLDER);
      expect(during.description).not.toContain(THUMB);
      store.dispatch({ type: EMOJI_MUTES_APPLY, revision: '2', availability: 'enabled', mutes: blank });
      expect(during.name).toBe('Mix');
      expect(during.title).toBe('');
      expect(during.description).toContain('Newsroom');
      expect(during.description).toContain('Ada');
      expect(during.description).not.toContain(THUMB);
    });

    const open = container.querySelector('.mix-list__link');

    expect(open.getAttribute('aria-label')).toBe('Mix');
    expect(open.getAttribute('aria-describedby')).toBe('mix-list-sources-mix-1');
    expect(open.getAttribute('href')).toBe('/timelines/mixes/mix-1');
    expect(container.querySelector('.mix-list__title').textContent).toBe('');
    expect(document.getElementById('mix-list-sources-mix-1').textContent).toContain('Newsroom');
    expect(open.innerHTML).not.toContain(THUMB);
  });
});
