/* eslint-disable react/prop-types, react/jsx-no-bind */
import React from 'react';
import { render } from '@testing-library/react';
import { fromJS, Set as ImmutableSet } from 'immutable';
import { IntlProvider } from 'react-intl';

const seen = [];

jest.mock('mastodon/containers/status_container', () => {
  const MockStatus = (props) => {
    seen.push(props.composerId || null);
    return <div data-testid='status' data-composer-id={props.composerId || ''} />;
  };

  return MockStatus;
});

jest.mock('mastodon/containers/account_container', () => () => null);
jest.mock('mastodon/components/hashtag', () => () => null);
jest.mock('mastodon/components/custom_emoji_result', () => () => null);

import Notification from 'mastodon/features/notifications/components/notification';
import SearchResults from 'mastodon/features/compose/components/search_results';
import { detailReferenceState } from 'mastodon/features/status/components/action_bar';

const intl = {
  formatMessage: ({ defaultMessage }) => defaultMessage,
  formatDate: () => 'date',
};

const mention = fromJS({
  type: 'mention',
  status: '42',
  created_at: '2026-11-07T00:00:00.000Z',
  account: { id: '1', acct: 'ada', url: 'https://example.test/ada', display_name_html: 'Ada', group: false },
});

describe('fullscreen composer ownership', () => {
  beforeEach(() => {
    seen.length = 0;
  });

  it('passes the fullscreen composer into notification and search posts', () => {
    render(
      <IntlProvider locale='en'>
        <div>
          <Notification
            notification={mention}
            composerId='fullscreen:notes'
            hidden={false}
            onMoveUp={() => {}}
            onMoveDown={() => {}}
            onMention={() => {}}
            onFavourite={() => {}}
            onReblog={() => {}}
            onToggleHidden={() => {}}
            intl={intl}
          />
          <SearchResults
            composerId='fullscreen:search'
            results={fromJS({ statuses: ['42'], accounts: [], hashtags: [] })}
            suggestions={fromJS([])}
            fetchSuggestions={() => {}}
            expandSearch={() => {}}
            dismissSuggestion={() => {}}
            searchTerm='cat'
            intl={intl}
          />
        </div>
      </IntlProvider>,
    );

    expect(seen).toEqual(['fullscreen:notes', 'fullscreen:search']);
  });

  it('reads detail reference state from the popup composer', () => {
    const status = fromJS({ id: '42' });
    const state = fromJS({
      compose: { id: null, privacy: 'public' },
      composers: {
        byId: {
          'fullscreen:a': { id: null, privacy: 'private' },
        },
      },
    }).setIn(['compose', 'references'], ImmutableSet())
      .setIn(['composers', 'byId', 'fullscreen:a', 'references'], ImmutableSet(['42']));

    expect(detailReferenceState(state, status, 'fullscreen:a')).toEqual({
      referenceCountLimit: false,
      selected: true,
      composePrivacy: 'private',
      editing: false,
    });
    expect(detailReferenceState(state, status, null).selected).toBe(false);
  });
});
