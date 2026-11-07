/* eslint-disable react/prop-types, react/jsx-no-bind */
import React from 'react';
import { render, waitFor } from '@testing-library/react';
import { Provider } from 'react-redux';
import { IntlProvider } from 'react-intl';
import { createStore } from 'redux';
import { fromJS } from 'immutable';

jest.mock('mastodon/components/status_list', () => () => null);
jest.mock('mastodon/features/ui/containers/status_list_container', () => () => null);
jest.mock('mastodon/features/account_gallery/components/media_items', () => () => null);
jest.mock('mastodon/features/compose/components/search_results', () => () => null);
jest.mock('mastodon/features/direct_timeline/containers/conversations_list_container', () => () => null);
jest.mock('mastodon/features/notifications', () => {
  const React = require('react');

  function NotificationsMock (props) {
    return React.createElement('div', {
      'data-testid': 'fullscreen-notifications',
      'data-passive': String(!!props.passive),
      'data-composer-id': props.composerId || '',
      'data-scroll-key': props.scrollKey || '',
    });
  }

  return { __esModule: true, default: NotificationsMock };
});

import FullscreenStream from '../stream';

const session = fromJS({
  source: { kind: 'notifications', title: 'Notifications' },
  presentation: { appearance: 'normal', columns: 1, scale: 'small' },
  viewId: 'view-9',
  composerId: 'fullscreen:notes',
});

const state = fromJS({
  statuses: {},
  filters: {},
  filterMatches: { generation: 0 },
});

describe('fullscreen notifications bundle', () => {
  it('passes passive, composerId, and scrollKey after the async column loads', async () => {
    const view = render(
      <Provider store={createStore(() => state)}>
        <IntlProvider locale='en'>
          <FullscreenStream session={session} />
        </IntlProvider>
      </Provider>,
    );

    const column = await waitFor(() => view.getByTestId('fullscreen-notifications'));

    expect(column.getAttribute('data-passive')).toBe('true');
    expect(column.getAttribute('data-composer-id')).toBe('fullscreen:notes');
    expect(column.getAttribute('data-scroll-key')).toBe('fullscreen:view-9');
  });
});
