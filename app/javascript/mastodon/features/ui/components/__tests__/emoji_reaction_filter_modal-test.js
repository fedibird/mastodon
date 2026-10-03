/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { fromJS } from 'immutable';

jest.mock('react-intl', () => {
  const interpolate = (defaultMessage, values) => {
    if (!values) {
      return defaultMessage;
    }

    return defaultMessage.split(/\{(\w+)\}/g).map((part, index) => (
      index % 2 === 1 ? values[part] : part
    )).join('');
  };
  const intl = {
    formatMessage: ({ defaultMessage }, values) => interpolate(defaultMessage, values),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => interpolate(defaultMessage, values),
  };
});

jest.mock('mastodon/components/emoji', () => {
  const React = require('react');

  return function Emoji({ emoji }) {
    return <img alt={emoji} />;
  };
});

import EmojiReactionFilterModal from '../emoji_reaction_filter_modal';

const state = fromJS({
  settings: {
    emoji_reactioned_statuses: { emojis: [], preferred_emojis: [] },
    columns: [
      { uuid: 'column-a', params: { emojis: [] } },
    ],
  },
  emoji_reactioned_statuses: {
    catalog: {
      items: [
        { name: '🎉', custom: false, domain: null, count: 3 },
      ],
      loaded: true,
      isLoading: false,
      error: null,
    },
  },
});

const noop = () => {};

describe('EmojiReactionFilterModal', () => {
  it('shows the picker without focusing the search box', () => {
    const store = createStore(current => current || state);

    render(
      <Provider store={store}>
        <EmojiReactionFilterModal columnId='column-a' onClose={noop} />
      </Provider>,
    );

    const search = screen.getByRole('searchbox', { name: 'Search emoji you have used' });

    expect(search).toBeInTheDocument();
    expect(search).not.toHaveFocus();
  });
});
