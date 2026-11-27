/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
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

const renderList = (store, props) => render(
  <Provider store={store}>
    <MemoryRouter>
      <MixList intl={intl} mixes={fromJS([])} {...props} />
    </MemoryRouter>
  </Provider>,
);

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

  it('projects a mix title and an account display name, and leaves a saved title literal', () => {
    const store = buildStore();
    const title = `Desk ${THUMB}`;
    const { container } = renderList(store, {
      mixes: fromJS([{
        id: 'mix-1',
        title,
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
          display_name_html: `Ada ${unicodeImg(THUMB)} ${localImg('10')}`,
          acct: 'ada@example.com',
        },
        10: {
          id: '10',
          title: 'Saved Ada',
          display_name: `Other ${THUMB}`,
          display_name_html: `Other ${unicodeImg(THUMB)}`,
          acct: 'other@example.com',
        },
      }),
    });

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [
          rule({ kind: 'unicode', native: THUMB }, '[ok]'),
          rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
        ],
      });
    });

    const open = screen.getByRole('link', { name: 'Desk [ok]' });
    const labels = Array.from(container.querySelectorAll('.mix-list__source-label')).map(node => node.textContent);

    expect(open.getAttribute('href')).toBe('/timelines/mixes/mix-1');
    expect(container.querySelector('.mix-list__title').textContent).toBe('Desk [ok]');
    expect(labels).toEqual(['Home', 'News :blob:', 'Ada [ok] [local]', 'Saved Ada']);
    expect(container.querySelector('.mix-list__sources').innerHTML).not.toContain(THUMB);
    expect(container.querySelector('.mix-list__sources').innerHTML).not.toContain('data-emoji-id');
    expect(screen.getByRole('link', { name: 'Mix settings' }).getAttribute('href')).toBe('/mixes/mix-1/edit');
  });

  it('names a blank mix and does not project a replacement emoji again', () => {
    const store = buildStore();
    const guard = createUnverifiedEmojiGuard();
    const during = { title: '', name: '' };
    const { container } = renderList(store, {
      mixes: fromJS([{
        id: 'mix-1',
        title: `Name ${THUMB}`,
        version: 1,
        sources: [{ type: 'home', params: {} }],
      }]),
    });
    const privacy = document.createElement('div');

    privacy.className = 'emoji-mutes-privacy-portal';
    privacy.appendChild(container);
    document.body.appendChild(privacy);
    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      const link = document.querySelector('.mix-list__link');

      during.title = link?.querySelector('.mix-list__title')?.textContent || '';
      during.name = link?.getAttribute('aria-label') || '';
    });

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [
          rule({ kind: 'unicode', native: THUMB }, CAT),
          rule({ kind: 'unicode', native: CAT }, '[cat]'),
        ],
      });
    });

    expect(container.querySelector('.mix-list__title').textContent).toBe(`Name ${CAT}`);
    expect(container.querySelector('.mix-list__link').getAttribute('aria-label')).toBe(`Name ${CAT}`);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      expect(during.title).toBe(`Name ${PLACEHOLDER}`);
      expect(during.name).toBe(`Name ${PLACEHOLDER}`);
      expect(during.title).not.toContain(THUMB);
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [
          rule({ kind: 'unicode', native: THUMB }, CAT),
          rule({ kind: 'unicode', native: CAT }, '[cat]'),
        ],
      });
      expect(during.title).toBe(`Name ${CAT}`);
      expect(during.name).not.toContain('[cat]');
    });

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '4',
        availability: 'enabled',
        mutes: [rule({ kind: 'unicode', native: THUMB }, '   ')],
      });
    });

    expect(container.querySelector('.mix-list__title').textContent).toBe('Name    ');
    expect(container.querySelector('.mix-list__link').getAttribute('aria-label')).toBe('Name    ');
    expect(container.querySelector('.mix-list__link').innerHTML).not.toContain(THUMB);
  });

  it('uses the mix column name when the stored title projects to nothing', () => {
    const store = buildStore();
    const { container } = renderList(store, {
      mixes: fromJS([{ id: 'mix-1', title: THUMB, version: 1, sources: [] }]),
    });

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [rule({ kind: 'unicode', native: THUMB }, '')],
      });
    });

    expect(container.querySelector('.mix-list__title').textContent).toBe('');
    expect(container.querySelector('.mix-list__link').getAttribute('aria-label')).toBe('Mix');
    expect(container.querySelector('.mix-list__link').getAttribute('href')).toBe('/timelines/mixes/mix-1');
    expect(container.querySelector('.mix-list__link').innerHTML).not.toContain(THUMB);
  });
});
