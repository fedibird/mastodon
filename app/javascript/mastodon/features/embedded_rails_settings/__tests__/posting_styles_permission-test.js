import React from 'react';
import { render } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { EmbeddedRailsSettings } from '..';

jest.mock('react-intl', () => ({ injectIntl: Component => Component, defineMessages: messages => messages, FormattedMessage: () => null }));

jest.mock('mastodon/initial_state', () => ({ isAdministrator: false }));
jest.mock('mastodon/components/icon', () => () => null);

it('does not mount a posting styles iframe or fetch settings for a non-administrator', () => {
  const dispatch = jest.fn();
  const { container, unmount } = render(
    <MemoryRouter>
      <EmbeddedRailsSettings screen='postingStyles' dispatch={dispatch} intl={{ formatMessage: ({ defaultMessage }) => defaultMessage }} />
    </MemoryRouter>,
  );
  expect(container.querySelector('iframe')).toBeNull();
  expect(dispatch).not.toHaveBeenCalled();
  unmount();
  expect(dispatch).not.toHaveBeenCalled();
});
