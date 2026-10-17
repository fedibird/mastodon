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

import en from '../../locales/en.json';
import ja from '../../locales/ja.json';

const account = { id: 'booster', display_name: 'Booster', username: 'booster', avatar: 'avatar.png' };
const original = { id: 'original', spoiler_text: '', content: '<p>Original &amp; 😀<br>post</p>' };
const wrapper = { id: 'wrapper', spoiler_text: '', content: '', reblog: original };
const payload = (status = wrapper, type = 'status') => ({ id: '10', type, account, status });
const state = (settings = {}) => fromJS({ settings: { notifications: { shows: {}, alerts: {}, sounds: {}, ...settings } } });

const deliver = (notification, messages = en, locale = 'en', settings = {}) => {
  const dispatch = jest.fn();
  updateNotifications(notification, messages, locale)(dispatch, () => state(settings));
  return dispatch;
};

beforeEach(() => {
  window.Notification = jest.fn(() => ({ addEventListener: jest.fn(), close: jest.fn() }));
});

afterEach(() => {
  delete window.Notification;
});

describe('followed boost desktop notifications', () => {
  it.each([
    ['en', en, 'Booster boosted a post'],
    ['ja', ja, 'Boosterさんがブーストしました'],
  ])('uses the booster and original content in %s', (locale, messages, title) => {
    const dispatch = deliver(payload(), messages, locale);
    expect(window.Notification).toHaveBeenCalledWith(title, {
      body: 'Original & 😀\npost', icon: 'avatar.png', tag: '10',
    });
    expect(dispatch).toHaveBeenCalledWith(expect.objectContaining({
      type: 'NOTIFICATIONS_UPDATE', notification: payload(), meta: { sound: 'boop' },
    }));
  });

  it('prefers the original CW and decodes HTML for plain text output', () => {
    deliver(payload({ ...wrapper, reblog: { ...original, spoiler_text: '<b>CW &amp; 😀</b>' } }));
    expect(window.Notification).toHaveBeenCalledWith('Booster boosted a post', expect.objectContaining({ body: 'CW & 😀' }));
  });

  it.each([undefined, null, {}, { reblog: {} }, { reblog: { content: null } }, { reblog: { spoiler_text: null } }])('handles partial status %p', status => {
    deliver({ ...payload(), status });
    expect(window.Notification).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({ body: '' }));
  });

  it('uses an English default for an untranslated boost title', () => {
    deliver(payload(), {}, 'fr');
    expect(window.Notification).toHaveBeenCalledWith('Booster boosted a post', expect.anything());
  });

  it.each([
    ['status', original, 'Booster just posted'],
    ['reblog', original, 'Booster boosted your post'],
    ['reblog', wrapper, 'Booster boosted your post'],
  ])('preserves %s notification meaning', (type, status, title) => {
    deliver(payload(status, type));
    expect(window.Notification).toHaveBeenCalledWith(title, expect.objectContaining({ body: status === wrapper ? '' : 'Original & 😀\npost' }));
  });

  it('preserves ordinary status CW priority', () => {
    deliver(payload({ ...original, spoiler_text: 'Ordinary CW' }));
    expect(window.Notification).toHaveBeenCalledWith('Booster just posted', expect.objectContaining({ body: 'Ordinary CW' }));
  });

  it('uses the existing status alert, column and sound settings', () => {
    const dispatch = deliver(payload(), en, 'en', { alerts: { status: false }, sounds: { status: false } });
    expect(window.Notification).not.toHaveBeenCalled();
    expect(dispatch).toHaveBeenCalledWith(expect.objectContaining({ type: 'NOTIFICATIONS_UPDATE', meta: undefined }));

    const hiddenDispatch = deliver(payload(), en, 'en', { shows: { status: false } });
    expect(hiddenDispatch).not.toHaveBeenCalledWith(expect.objectContaining({ type: 'NOTIFICATIONS_UPDATE' }));
    expect(hiddenDispatch).toHaveBeenCalledWith({ type: 'NOTIFICATIONS_UPDATE_NOOP', meta: { sound: 'boop' } });
    expect(window.Notification).toHaveBeenCalledTimes(1);
  });
});
