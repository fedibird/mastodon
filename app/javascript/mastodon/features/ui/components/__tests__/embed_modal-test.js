import { render, screen, waitFor } from '@testing-library/react';
import React from 'react';

jest.mock('mastodon/api', () => {
  const get = jest.fn(() => Promise.resolve({ data: { html: '<iframe src="https://example.test/embed"></iframe>' } }));
  const api = jest.fn(() => ({ get }));
  api.get = get;
  return api;
});

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import api from 'mastodon/api';
import EmbedModal from '../embed_modal';

describe('EmbedModal', () => {
  it('loads oEmbed HTML with the status id', async () => {
    render(<EmbedModal id='42' onClose={jest.fn()} onError={jest.fn()} />);

    await waitFor(() => expect(api.get).toHaveBeenCalledWith('/api/web/embeds/42'));
    expect(screen.getByDisplayValue(/iframe/)).toBeInTheDocument();
  });
});
