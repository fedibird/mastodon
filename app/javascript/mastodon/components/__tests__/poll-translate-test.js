/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'ja',
    now: () => Date.now(),
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('../relative_timestamp', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/features/emoji/emoji', () => text => text);
jest.mock('escape-html', () => text => text);

import Poll from '../poll';

const poll = (translation) => fromJS({
  id: 'p1',
  multiple: false,
  expired: false,
  expires_at: null,
  voted: false,
  votes_count: 0,
  voters_count: 0,
  own_votes: [],
  emojis: [],
  options: [
    {
      title: 'Yes',
      title_emojified: 'Yes',
      votes_count: 0,
      translation,
    },
  ],
});

const renderPoll = (mode) => render(
  <Poll
    poll={poll(mode ? { title: 'はい', titleHtml: 'はい' } : undefined)}
    translationMode={mode}
    sourceLang='en'
    targetLang='ja'
    lang='en'
    disabled={false}
    refresh={jest.fn()}
    onVote={jest.fn()}
  />,
);

describe('Poll translation display modes', () => {
  it('shows the original option in original mode', () => {
    const { container } = renderPoll('original');

    expect(screen.getByText('Yes')).toBeTruthy();
    expect(screen.queryByText('はい')).toBeNull();
    expect(container.querySelector('.poll__option__text').getAttribute('lang')).toBe('en');
  });

  it('shows the translated option in translated mode', () => {
    const { container } = renderPoll('translated');

    expect(screen.getByText('はい')).toBeTruthy();
    expect(screen.queryByText('Yes')).toBeNull();
    expect(container.querySelector('.poll__option__text').getAttribute('lang')).toBe('ja');
  });

  it('shows both option languages in bilingual mode', () => {
    const { container } = renderPoll('bilingual');
    const source = container.querySelector('.status-translation-pair__source');
    const target = container.querySelector('.status-translation-pair__target');

    expect(source.textContent).toBe('Yes');
    expect(source.getAttribute('lang')).toBe('en');
    expect(target.textContent).toBe('はい');
    expect(target.getAttribute('lang')).toBe('ja');
    expect(target.className).toContain('poll__option__translation');
    expect(container.querySelector('.poll__number')).toBeNull();
  });
});
