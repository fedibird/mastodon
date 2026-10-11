import { render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { createStore } from 'redux';

const policy = { value: 'default' };

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

jest.mock('../../../initial_state', () => ({
  me: '1',
  profile_directory: false,
  trendsEnabled: false,
  showTrends: false,
  enableLimitedTimeline: false,
  enablePersonalTimeline: false,
  enableFederatedTimeline: false,
  enableLocalTimeline: false,
  enableEmptyColumn: false,
  defaultColumnWidth: 'wide',
  get isAdministrator () {
    return false;
  },
  get new_features_policy () {
    return policy.value;
  },
}));

jest.mock('mastodon/actions/accounts', () => ({
  fetchFollowRequests: () => ({ type: 'TEST_FOLLOW_REQUESTS' }),
}));

jest.mock('mastodon/actions/favourite_domains', () => ({
  fetchFavouriteDomains: () => ({ type: 'TEST_DOMAINS' }),
}));

jest.mock('mastodon/actions/favourite_tags', () => ({
  fetchFavouriteTags: () => ({ type: 'TEST_TAGS' }),
}));

jest.mock('mastodon/actions/scheduled_statuses', () => ({
  fetchScheduledStatuses: () => ({ type: 'TEST_SCHEDULED' }),
}));

jest.mock('../../compose/containers/navigation_container', () => () => null);
jest.mock('../containers/trends_container', () => () => null);
jest.mock('mastodon/features/ui/components/link_footer', () => () => null);

import GettingStarted from '../index';

const intl = {
  formatMessage: (message) => message.defaultMessage,
};

const store = createStore(() => fromJS({
  accounts: { 1: { id: '1', locked: false } },
  settings: { columns: [] },
}));

const renderMenu = (multiColumn) => render(
  <Provider store={store}>
    <MemoryRouter>
      <GettingStarted intl={intl} multiColumn={multiColumn} />
    </MemoryRouter>
  </Provider>,
);

const personalLinks = () => screen.getAllByRole('link').map(link => link.getAttribute('href'));

describe('getting started mix link', () => {
  beforeEach(() => {
    policy.value = 'default';
    window.innerWidth = 800;
  });

  it('places Mix between Lists and Circles in both layouts', () => {
    const single = renderMenu(false);
    let links = personalLinks();

    expect(screen.getAllByRole('link', { name: 'Mix' })).toHaveLength(1);
    expect(links[links.indexOf('/lists') + 1]).toBe('/mixes');
    expect(links[links.indexOf('/mixes') + 1]).toBe('/circles');
    expect(screen.getByRole('link', { name: 'Mix' }).querySelector('.fa-random')).toBeTruthy();
    expect(single.container.querySelector('.getting-started__wrapper').style.height).toBe('622px');
    single.unmount();

    policy.value = 'conservative';
    const multi = renderMenu(true);

    links = personalLinks();
    expect(screen.getAllByRole('link', { name: 'Mix' })).toHaveLength(1);
    expect(links[links.indexOf('/lists') + 1]).toBe('/mixes');
    expect(links[links.indexOf('/mixes') + 1]).toBe('/circles');
    expect(multi.container.querySelector('.getting-started__wrapper').style.height).toBe('630px');
  });
});
