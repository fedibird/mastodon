/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';
import { fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  autoPlayEmoji: false,
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: ({ defaultMessage }) => defaultMessage };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage, values }) => {
      if (!values) return defaultMessage;

      return defaultMessage.split(/\{(\w+)\}/).map((part, index) => (
        index % 2 === 1 ? <React.Fragment key={`${part}-${index}`}>{values[part]}</React.Fragment> : part
      ));
    },
  };
});

jest.mock('mastodon/components/button', () => ({ text }) => <button type='button'>{text}</button>);

import AddedToFilter from '../added_to_filter';
import SelectFilter from '../select_filter';

const state = fromJS({
  filters: {
    f1: {
      id: 'f1',
      title: 'Work :fedibird:',
      keywords: [],
      context: ['home'],
      expires_at: null,
    },
  },
  custom_emojis: [{
    shortcode: 'fedibird',
    url: 'https://example.test/fedibird.gif',
    static_url: 'https://example.test/fedibird.png',
  }],
});

const store = createStore(() => state);

describe('custom emoji filter titles', () => {
  it('renders custom emoji while searching by the raw title', () => {
    const { container } = render(
      <Provider store={store}>
        <SelectFilter onSelectFilter={jest.fn()} onNewFilter={jest.fn()} />
      </Provider>,
    );

    expect(container.querySelector('.filter-modal__select-filter img.custom-emoji')).toHaveAttribute('alt', ':fedibird:');
    expect(screen.getByRole('button', { name: /Work/ })).toBeInTheDocument();

    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'fedibird' } });

    expect(screen.getByRole('button', { name: /Work/ })).toBeInTheDocument();
  });

  it('renders custom emoji in the added-to-filter message', () => {
    const { container } = render(
      <Provider store={store}>
        <AddedToFilter filterId='f1' onClose={jest.fn()} />
      </Provider>,
    );

    expect(container.querySelector('img.custom-emoji')).toHaveAttribute('alt', ':fedibird:');
    expect(screen.getByText(/This post has been added/)).toBeInTheDocument();
  });
});
