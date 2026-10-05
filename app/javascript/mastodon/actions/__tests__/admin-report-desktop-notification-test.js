import { fromJS } from 'immutable';

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
  getLinks: jest.fn(),
}));

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../accounts', () => ({
  fetchRelationships: jest.fn(() => ({ type: 'RELATIONSHIPS_FETCH' })),
}));

jest.mock('../markers', () => ({
  submitMarkers: jest.fn(() => ({ type: 'MARKERS_SUBMIT' })),
}));

jest.mock('../settings', () => ({
  saveSettings: jest.fn(() => ({ type: 'SETTINGS_SAVE' })),
}));

jest.mock('../importer', () => ({
  importFetchedAccount: jest.fn(account => ({ type: 'ACCOUNT_IMPORT', account })),
  importFetchedAccounts: jest.fn(),
  importFetchedStatus: jest.fn(status => ({ type: 'STATUS_IMPORT', status })),
  importFetchedStatuses: jest.fn(),
}));

jest.mock('mastodon/initial_state', () => ({
  me: 'me',
  usePendingItems: false,
  enableReaction: true,
  enableStatusReference: true,
}));

import { updateNotifications } from '../notifications';

const getState = () => fromJS({
  settings: {
    notifications: {
      shows: {},
      alerts: {},
      sounds: {},
    },
  },
});

const reporter = {
  id: '1',
  username: 'alice',
  display_name: 'Alice',
  avatar: 'https://example.test/alice.png',
};

const target = {
  id: '2',
  username: 'bob',
  acct: 'bob',
  display_name: 'Bob',
};

const adminReport = (report = { target_account: target }) => ({
  id: 'n1',
  type: 'admin.report',
  account: reporter,
  report,
});

const captureNotification = () => {
  const created = [];

  window.Notification = jest.fn((title, options) => {
    const notify = {
      title,
      options,
      addEventListener: jest.fn(),
      close: jest.fn(),
    };

    created.push(notify);
    return notify;
  });

  return created;
};

describe('admin.report desktop notifications', () => {
  it('formats the title with the reporter and the reported account', () => {
    const created = captureNotification();
    const dispatch = jest.fn();

    updateNotifications(
      adminReport(),
      { 'notification.admin.report': '{name} reported {target}' },
      'en',
    )(dispatch, getState);

    expect(created).toHaveLength(1);
    expect(created[0].title).toBe('Alice reported Bob');
    expect(dispatch).toHaveBeenCalled();
  });

  it('formats the Japanese title when that message is supplied', () => {
    const created = captureNotification();

    updateNotifications(
      adminReport(),
      { 'notification.admin.report': '{name}さんが{target}さんを通報しました' },
      'ja',
    )(jest.fn(), getState);

    expect(created[0].title).toBe('AliceさんがBobさんを通報しました');
  });

  it('does not throw when the report or target account is missing', () => {
    const created = captureNotification();

    expect(() => {
      updateNotifications(
        adminReport(null),
        { 'notification.admin.report': '{name} reported {target}' },
        'en',
      )(jest.fn(), getState);
    }).not.toThrow();

    expect(created[0].title).toBe('Alice reported ');

    expect(() => {
      updateNotifications(
        adminReport({}),
        { 'notification.admin.report': '{name} reported {target}' },
        'en',
      )(jest.fn(), getState);
    }).not.toThrow();

    expect(created[1].title).toBe('Alice reported ');
  });

  it('falls back from an empty target display name to the username', () => {
    const created = captureNotification();

    updateNotifications(
      adminReport({
        target_account: {
          display_name: '',
          username: 'bobuser',
          acct: 'bobuser@example.test',
        },
      }),
      { 'notification.admin.report': '{name} reported {target}' },
      'en',
    )(jest.fn(), getState);

    expect(created[0].title).toBe('Alice reported bobuser');
  });
});
