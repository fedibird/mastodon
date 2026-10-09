import { render, screen } from '@testing-library/react';
import React from 'react';
import { MemoryRouter } from 'react-router-dom';

const flags = {
  profile_directory: true,
  trendsEnabled: true,
  showTrends: false,
  enableLimitedTimeline: false,
  enableFederatedTimeline: true,
  enableLocalTimeline: true,
  enablePersonalTimeline: false,
  isAdministrator: false,
  new_features_policy: 'default',
};

jest.mock('mastodon/initial_state', () => ({
  get profile_directory () {
    return flags.profile_directory;
  },
  get trendsEnabled () {
    return flags.trendsEnabled;
  },
  get showTrends () {
    return flags.showTrends;
  },
  get enableLimitedTimeline () {
    return flags.enableLimitedTimeline;
  },
  get enableFederatedTimeline () {
    return flags.enableFederatedTimeline;
  },
  get enableLocalTimeline () {
    return flags.enableLocalTimeline;
  },
  get enablePersonalTimeline () {
    return flags.enablePersonalTimeline;
  },
  get isAdministrator () {
    return flags.isAdministrator;
  },
  get new_features_policy () {
    return flags.new_features_policy;
  },
}));

jest.mock('react-intl', () => ({
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

jest.mock('../follow_requests_nav_link', () => () => null);
jest.mock('../scheduled_statuses_nav_link', () => () => null);
jest.mock('../list_panel', () => () => null);
jest.mock('../favourite_domain_panel', () => () => null);
jest.mock('../favourite_tag_panel', () => () => null);
jest.mock('../notifications_counter_icon', () => () => null);
jest.mock('mastodon/features/getting_started/containers/trends_container', () => () => null);

import NavigationPanel from '../navigation_panel';

const hrefs = () => screen.getAllByRole('link').map(link => link.getAttribute('href'));

const renderPanel = () => render(
  <MemoryRouter>
    <NavigationPanel />
  </MemoryRouter>,
);

describe('NavigationPanel discovery links', () => {
  beforeEach(() => {
    flags.profile_directory = true;
    flags.trendsEnabled = true;
    flags.enableFederatedTimeline = true;
    flags.enableLocalTimeline = true;
    flags.isAdministrator = false;
    flags.new_features_policy = 'default';
  });

  it('places group directory, directory, and explore immediately after the federated timeline', () => {
    renderPanel();

    const links = hrefs();
    const start = links.indexOf('/timelines/public');

    expect(links.slice(start, start + 4)).toEqual([
      '/timelines/public',
      '/group_directory',
      '/directory',
      '/explore',
    ]);
    expect(links[start - 1]).toBe('/timelines/public/local');
    expect(links[start + 4]).toBe('/accounts/2');
  });

  it('omits directory and explore when those features are disabled', () => {
    flags.profile_directory = false;
    flags.trendsEnabled = false;
    renderPanel();

    const links = hrefs();
    const start = links.indexOf('/timelines/public');

    expect(links.slice(start, start + 2)).toEqual(['/timelines/public', '/group_directory']);
    expect(links).not.toContain('/directory');
    expect(links).not.toContain('/explore');
    expect(links[start + 2]).toBe('/accounts/2');
  });

  it('keeps the discovery group when the federated timeline is disabled', () => {
    flags.enableFederatedTimeline = false;
    flags.enableLocalTimeline = false;
    renderPanel();

    const links = hrefs();

    expect(links).not.toContain('/timelines/public');
    expect(links).not.toContain('/timelines/public/local');
    expect(links.slice(links.indexOf('/group_directory'), links.indexOf('/group_directory') + 3)).toEqual([
      '/group_directory',
      '/directory',
      '/explore',
    ]);
  });

  it('shows Mix to administrators and beta testers', () => {
    flags.isAdministrator = true;
    renderPanel();

    const adminLinks = hrefs();

    expect(adminLinks).toContain('/mixes');
    expect(adminLinks[adminLinks.indexOf('/lists') + 1]).toBe('/mixes');
  });

  it('hides Mix from accounts that are not administrators or beta testers', () => {
    renderPanel();

    expect(hrefs()).not.toContain('/mixes');
  });
});
