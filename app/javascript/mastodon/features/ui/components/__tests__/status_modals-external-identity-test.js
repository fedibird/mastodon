/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: 'owner',
  disableRelativeTime: true,
  autoPlayEmoji: false,
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage;

      if (values) {
        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key]);
        });
      }

      return message;
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('../../../../components/button', () => {
  const React = require('react');

  return React.forwardRef((props, ref) => {
    React.useImperativeHandle(ref, () => ({ focus: jest.fn() }));
    return null;
  });
});
jest.mock('../../../../components/status_content', () => () => null);
jest.mock('../../../../components/attachment_list', () => () => null);
jest.mock('mastodon/components/attachment_list', () => () => null);
jest.mock('mastodon/features/compose/components/privacy_dropdown', () => () => null);
jest.mock('../../../../components/avatar', () => () => <span data-testid='account-avatar' />);
jest.mock('../../../../components/display_name', () => () => <span data-testid='account-name'>Owner Face</span>);
jest.mock('../../../../components/absolute_timestamp', () => () => <span>time</span>);
jest.mock('../../../../components/relative_timestamp', () => () => <span>time</span>);
jest.mock('mastodon/components/icon', () => ({ id }) => <i data-icon={id} />);
jest.mock('../../../../components/icon', () => ({ id }) => <i data-icon={id} />);
jest.mock('mastodon/actions/boosts', () => ({ changeBoostPrivacy: jest.fn() }));

import BoostModal from '../boost_modal';
import ActionsModal from '../actions_modal';

const store = createStore(() => fromJS({
  boosts: { new: { privacy: 'public' } },
  compose: { prohibited_visibilities: [] },
}));

const account = { id: 'owner', acct: 'owner', username: 'owner', display_name: 'Owner Face', url: 'https://fedibird.test/@owner', group: false };

const status = (overrides = {}) => fromJS({
  id: 's1',
  account,
  visibility: 'public',
  url: 'https://fedibird.test/@owner/s1',
  created_at: '2024-01-01T00:00:00.000Z',
  media_attachments: [],
  reblogged: false,
  ...overrides,
});

const external = (fedibird = {}, overrides = {}) => status({
  visibility: 'external',
  url: null,
  fedibird_external: {
    protocol: 'rss',
    source_title: 'Blog name',
    canonical_url: 'https://blog.example/posts/1',
    presentation: { kind: 'external_source', name: 'Blog name', subtitle: 'RSS', source_url: 'https://blog.example/', icon_url: null, thumbnail_url: null, byline_name: null },
    ...fedibird,
  },
  ...overrides,
});

const renderBoost = value => render(
  <Provider store={store}>
    <BoostModal status={value} onReblog={jest.fn()} onClose={jest.fn()} />
  </Provider>,
);

const renderActions = value => render(<ActionsModal status={value} actions={[]} onClick={jest.fn()} />);

describe.each([
  ['boost modal', renderBoost],
  ['actions modal', renderActions],
])('%s time link', (_label, renderModal) => {
  it('links an external projection to the article, not to a status url', () => {
    renderModal(external());
    const time = document.querySelector('.status__relative-time');

    expect(time.tagName).toBe('A');
    expect(time.getAttribute('href')).toBe('https://blog.example/posts/1');
    expect(time.getAttribute('target')).toBe('_blank');
    expect(time.getAttribute('rel')).toBe('noopener noreferrer');
  });

  it('shows the time as plain text when the article url is unknown', () => {
    renderModal(external({ canonical_url: null }));
    const time = document.querySelector('.status__relative-time');

    expect(time.tagName).toBe('SPAN');
    expect(time.getAttribute('href')).toBeNull();
    expect(document.querySelectorAll('a:not([href])').length).toBe(0);
  });

  it('names the source and never the owner for an external projection', () => {
    renderModal(external());

    expect(document.querySelector('.external-source-identity__name').textContent).toBe('Blog name');
    expect(screen.queryByTestId('account-name')).toBeNull();
    expect(screen.queryByTestId('account-avatar')).toBeNull();
  });

  it('keeps the status url and the owner identity for an ordinary status', () => {
    renderModal(status());
    const time = document.querySelector('.status__relative-time');

    expect(time.tagName).toBe('A');
    expect(time.getAttribute('href')).toBe('https://fedibird.test/@owner/s1');
    expect(screen.getByTestId('account-name')).toBeTruthy();
    expect(document.querySelector('[data-external-source]')).toBeNull();
  });
});
