import { fromJS } from 'immutable';

import { notificationFilterFlags } from '../notification_filter';
import { NOTIFICATIONS_UPDATE } from '../notifications';
import { importFetchedAccount, importFetchedStatus } from '../importer';

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
  getLinks: jest.fn(),
}));

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('intl-messageformat', () => function IntlMessageFormat() {
  return { format: () => 'title' };
});

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
  enableLimitedTimeline: false,
  hideDirectFromTimeline: false,
  hidePersonalFromTimeline: false,
  maxFrequentlyUsedEmojis: 16,
}));

jest.mock('mastodon/features/emoji/emoji', () => ({
  buildCustomEmojis: () => [],
  categoriesFromEmojis: () => [],
}));

import { updateNotifications } from '../notifications';
import rootReducer from '../../reducers';

const hideResult = {
  filter: {
    id: '1',
    title: 'spam',
    context: ['notifications'],
    filter_action: 'hide',
  },
};

const warnResult = {
  filter: {
    id: '2',
    title: 'spoiler',
    context: ['notifications'],
    filter_action: 'warn',
  },
};

const homeHideResult = {
  filter: {
    id: '3',
    title: 'home only',
    context: ['home'],
    filter_action: 'hide',
  },
};

const notification = (type, filtered) => ({
  id: 'n1',
  type,
  account: {
    id: 'a1',
    username: 'alice',
    display_name: 'Alice',
    avatar: '',
  },
  status: {
    id: 's1',
    spoiler_text: '',
    content: '<p>hello</p>',
    filtered,
  },
});

const getState = () => fromJS({
  settings: {
    notifications: {
      shows: {},
      alerts: {},
      sounds: {},
    },
  },
});

describe('notificationFilterFlags', () => {
  it('drops a mention matching a notifications hide filter', () => {
    expect(notificationFilterFlags(notification('mention', [hideResult]))).toEqual({
      drop: true,
      filtered: false,
    });
  });

  it('keeps a mention matching a notifications warn filter', () => {
    expect(notificationFilterFlags(notification('mention', [warnResult]))).toEqual({
      drop: false,
      filtered: true,
    });
  });

  it('drops a status notification matching a notifications hide filter', () => {
    expect(notificationFilterFlags(notification('status', [hideResult])).drop).toEqual(true);
  });

  it('drops a status_reference matching a notifications hide filter', () => {
    expect(notificationFilterFlags(notification('status_reference', [hideResult])).drop).toEqual(true);
  });

  it('drops a scheduled_status matching a notifications hide filter', () => {
    expect(notificationFilterFlags(notification('scheduled_status', [hideResult])).drop).toEqual(true);
  });

  it('ignores hide filters that are not in the notifications context', () => {
    expect(notificationFilterFlags(notification('mention', [homeHideResult]))).toEqual({
      drop: false,
      filtered: false,
    });
  });

  it('treats an empty filtered array as unfiltered', () => {
    expect(notificationFilterFlags(notification('mention', []))).toEqual({
      drop: false,
      filtered: false,
    });
  });

  it('treats a missing filtered field as unfiltered', () => {
    const payload = notification('mention');
    delete payload.status.filtered;

    expect(notificationFilterFlags(payload)).toEqual({
      drop: false,
      filtered: false,
    });
  });

  it('treats notifications without a status as unfiltered', () => {
    expect(notificationFilterFlags({
      type: 'mention',
      account: { id: 'a1' },
    })).toEqual({
      drop: false,
      filtered: false,
    });
  });

  it('drops when warn and hide results are both present', () => {
    expect(notificationFilterFlags(notification('mention', [warnResult, hideResult])).drop).toEqual(true);
  });

  it('does not filter favourite notifications even with a hide FilterResult', () => {
    expect(notificationFilterFlags(notification('favourite', [hideResult]))).toEqual({
      drop: false,
      filtered: false,
    });
  });
});

describe('updateNotifications FilterResult integration', () => {
  const intlMessages = { 'notification.mention': '{name} mentioned you' };

  beforeEach(() => {
    window.Notification = jest.fn();
  });

  it('does not update, sound, or desktop-notify a hidden mention', () => {
    const dispatch = jest.fn();

    updateNotifications(notification('mention', [hideResult]), intlMessages, 'en')(dispatch, getState);

    expect(dispatch).not.toHaveBeenCalled();
    expect(window.Notification).not.toHaveBeenCalled();
  });

  it('imports and updates a warn mention without sound or desktop notification', () => {
    const dispatch = jest.fn();
    const payload = notification('mention', [warnResult]);

    updateNotifications(payload, intlMessages, 'en')(dispatch, getState);

    expect(importFetchedAccount).toHaveBeenCalledWith(payload.account);
    expect(importFetchedStatus).toHaveBeenCalledWith(payload.status);
    expect(dispatch).toHaveBeenCalledWith(expect.objectContaining({
      type: NOTIFICATIONS_UPDATE,
      notification: payload,
      meta: undefined,
    }));
    expect(window.Notification).not.toHaveBeenCalled();
  });
});

describe('root reducer', () => {
  it('does not keep a notification_filters store', () => {
    const state = rootReducer(undefined, { type: '@@INIT' });

    expect(state.has('notification_filters')).toEqual(false);
    expect(state.has('filters')).toEqual(true);
  });
});
