import { render, screen } from '@testing-library/react';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

let mockStatusPageUrl = 'https://status.example.com';

jest.mock('mastodon/initial_state', () => ({
  invitesEnabled: false,
  limitedFederationMode: false,
  version: '1.0.0',
  repository: 'fedibird/mastodon',
  source_url: 'https://github.com/fedibird/mastodon',
  get statusPageUrl () {
    return mockStatusPageUrl;
  },
}));

jest.mock('react-intl', () => {
  const intl = { formatMessage: ({ defaultMessage }) => defaultMessage };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/utils/log_out', () => ({
  logOut: jest.fn(),
}));

jest.mock('mastodon/actions/modal', () => ({
  openModal: jest.fn(() => ({ type: 'OPEN_MODAL' })),
}));

import LinkFooter from '../link_footer';

const store = createStore(state => state, {});

const renderFooter = () => render(
  <Provider store={store}>
    <LinkFooter />
  </Provider>,
);

describe('<LinkFooter />', () => {
  it('links to the status page when a URL is configured', () => {
    mockStatusPageUrl = 'https://status.example.com';
    renderFooter();

    const link = screen.getByRole('link', { name: 'Status' });
    expect(link).toHaveAttribute('href', 'https://status.example.com');
    expect(link).toHaveAttribute('target', '_blank');
    expect(link).toHaveAttribute('rel', 'noopener noreferrer');
  });

  it('hides the status link when the URL is blank', () => {
    mockStatusPageUrl = '';
    renderFooter();

    expect(screen.queryByRole('link', { name: 'Status' })).not.toBeInTheDocument();
  });
});
