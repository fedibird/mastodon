import React from 'react';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { Provider } from 'react-redux';
import { createStore, applyMiddleware } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';
import { fromJS } from 'immutable';
import NotificationSettings from '../notification_settings';
import pending from '../../../../reducers/account_notifications';
import relationships from '../../../../reducers/relationships';
import dropdown from '../../../../reducers/dropdown_menu';
import api from '../../../../api';
import { isUserTouching } from '../../../../is_mobile';
import { openDropdownMenu } from '../../../../actions/dropdown_menu';
import { RELATIONSHIPS_FETCH_SUCCESS } from '../../../../actions/accounts';
import en from '../../../../locales/en.json';
import ja from '../../../../locales/ja.json';

jest.mock('../../../../api', () => ({ __esModule: true, default: jest.fn() }));
jest.mock('react-intl', () => ({ defineMessages: messages => messages, injectIntl: Component => Component }));
jest.mock('mastodon/initial_state', () => ({ me: 'self' }));
jest.mock('../../../../is_mobile', () => ({ isUserTouching: jest.fn(() => false) }));

const base = { id: '1', following: true, requested: false, notifying: false, notifying_reblogs: false };
const setup = (changes = {}, messages = en, accountId = '1') => {
  const store = createStore(combineReducers({ relationships, account_notifications: pending, dropdown_menu: dropdown }), fromJS({ relationships: { [accountId]: { ...base, id: accountId, ...changes } } }), applyMiddleware(thunk));
  const intl = { formatMessage: ({ id, defaultMessage }) => messages[id] || defaultMessage };
  const view = render(<Provider store={store}><NotificationSettings accountId={accountId} intl={intl} /></Provider>);
  return { store, intl, ...view };
};
const open = async () => {
  const bell = screen.getByRole('button', { name: /Notification settings|通知設定/ });
  await act(async () => {
    fireEvent.mouseDown(bell);
    fireEvent.click(bell);
  });
  return bell;
};
const expectSlideSwitch = (name, checked) => {
  const row = screen.getByRole('menuitemcheckbox', { name });
  const toggle = row.querySelector('.react-toggle');
  expect(row.querySelector('.setting-toggle__label')).toHaveTextContent(name);
  expect(toggle).not.toBeNull();
  expect(toggle).toHaveAttribute('aria-hidden', 'true');
  expect(toggle.classList.contains('react-toggle--checked')).toBe(checked);
  expect(row.querySelector('input, [role="switch"], [role="checkbox"]')).toBeNull();
};

beforeEach(() => {
  isUserTouching.mockReturnValue(false);
});

describe('profile notification settings menu', async () => {
  it.each([[false, false], [true, false], [false, true], [true, true]])('shows server values and active bell for posts=%s boosts=%s', async (notifying, notifying_reblogs) => {
    setup({ notifying, notifying_reblogs });
    const bell = await open();
    expect(bell.classList.contains('active')).toBe(notifying || notifying_reblogs);
    expect(bell).toHaveAttribute('aria-expanded', 'true');
    expect(bell).toHaveAttribute('aria-haspopup', 'menu');
    expect(screen.getByRole('menu')).toHaveAttribute('id', bell.getAttribute('aria-controls'));
    expect(screen.getByRole('menuitemcheckbox', { name: 'Notify about new posts' })).toHaveAttribute('aria-checked', String(notifying));
    expect(screen.getByRole('menuitemcheckbox', { name: 'Notify about boosts' })).toHaveAttribute('aria-checked', String(notifying_reblogs));
    expectSlideSwitch('Notify about new posts', notifying);
    expectSlideSwitch('Notify about boosts', notifying_reblogs);
  });

  it('edits both settings for a pending follow with Japanese labels', async () => {
    setup({ following: false, requested: true, notifying: true }, ja);
    await open();
    expect(screen.getByRole('menuitemcheckbox', { name: '新しい投稿を通知' })).toHaveAttribute('aria-checked', 'true');
    expect(screen.getByRole('menuitemcheckbox', { name: 'ブーストを通知' })).toBeEnabled();
    expectSlideSwitch('新しい投稿を通知', true);
    expectSlideSwitch('ブーストを通知', false);
  });

  it.each([{ following: false }, { following: false, requested: false }])('hides the bell when not followed/requested: %p', async value => {
    setup(value);
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('hides the bell for the current user', async () => {
    setup({}, en, 'self');
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('opens from the keyboard, navigates rows, closes with Escape and restores focus', async () => {
    setup();
    const bell = screen.getByRole('button');
    bell.focus();
    await act(async () => {
      fireEvent.keyPress(bell, { key: 'Enter', charCode: 13 });
    });
    const rows = screen.getAllByRole('menuitemcheckbox');
    expect(rows[0]).toHaveFocus();
    fireEvent.keyDown(rows[0], { key: 'ArrowDown' });
    expect(rows[1]).toHaveFocus();
    fireEvent.keyDown(rows[1], { key: 'Tab', shiftKey: true });
    expect(rows[0]).toHaveFocus();
    fireEvent.keyDown(rows[0], { key: 'Tab' });
    expect(rows[1]).toHaveFocus();
    fireEvent.keyDown(rows[1], { key: 'Home' });
    expect(rows[0]).toHaveFocus();
    fireEvent.keyDown(rows[0], { key: 'End' });
    expect(rows[1]).toHaveFocus();
    fireEvent.keyDown(rows[1], { key: 'Escape' });
    expect(screen.queryByRole('menu')).toBeNull();
    expect(bell).toHaveFocus();
    expect(bell).toHaveAttribute('aria-expanded', 'false');
  });

  it('closes on outside click or touch, and when another dropdown opens', async () => {
    const { store } = setup();
    const bell = await open();
    fireEvent.click(document.body);
    expect(screen.queryByRole('menu')).toBeNull();
    await open();
    fireEvent.touchEnd(document.body);
    expect(screen.queryByRole('menu')).toBeNull();
    await open();
    await act(async () => {
      store.dispatch(openDropdownMenu('other-menu', false));
    });
    expect(screen.queryByRole('menu')).toBeNull();
    expect(bell).toHaveAttribute('aria-expanded', 'false');
  });

  it('keeps a touch-opened menu anchored instead of opening the actions modal', async () => {
    isUserTouching.mockReturnValue(true);
    const { store } = setup();
    await open();
    expect(screen.getByRole('menu')).toBeInTheDocument();
    expect(store.getState().getIn(['dropdown_menu', 'openId'])).toMatch(/^action:/);
  });

  it('holds server values and disables both rows until saving succeeds', async () => {
    let resolve;
    const post = jest.fn(() => new Promise(yes => {
      resolve = yes;
    }));
    api.mockReturnValue({ post });
    setup({ notifying: true });
    await open();
    const boosts = screen.getByRole('menuitemcheckbox', { name: 'Notify about boosts' });
    fireEvent.click(boosts);
    fireEvent.click(boosts);
    fireEvent.click(screen.getByRole('menuitemcheckbox', { name: 'Notify about new posts' }));
    expect(post).toHaveBeenCalledTimes(1);
    expect(post).toHaveBeenCalledWith('/api/v1/accounts/1/follow', { notify_reblogs: true });
    expect(boosts).toHaveAttribute('aria-checked', 'false');
    expectSlideSwitch('Notify about boosts', false);
    expectSlideSwitch('Notify about new posts', true);
    screen.getAllByRole('menuitemcheckbox').forEach(row => expect(row).toBeDisabled());
    await act(async () => {
      resolve({ data: { ...base, notifying: true, notifying_reblogs: true } });
    });
    expect(boosts).toHaveAttribute('aria-checked', 'true');
    expectSlideSwitch('Notify about boosts', true);
    screen.getAllByRole('menuitemcheckbox').forEach(row => expect(row).toBeEnabled());
  });

  it('keeps values after failure, releases the lock and reflects a relationship refetch', async () => {
    api.mockReturnValue({ post: jest.fn().mockRejectedValue(new Error('offline')) });
    const { store } = setup({ notifying: true });
    await open();
    await act(async () => {
      fireEvent.click(screen.getByRole('menuitemcheckbox', { name: 'Notify about boosts' }));
    });
    expect(screen.getByRole('menuitemcheckbox', { name: 'Notify about boosts' })).toHaveAttribute('aria-checked', 'false');
    expect(screen.getByRole('menuitemcheckbox', { name: 'Notify about new posts' })).toHaveAttribute('aria-checked', 'true');
    await act(async () => {
      store.dispatch({ type: RELATIONSHIPS_FETCH_SUCCESS, relationships: [{ ...base, notifying_reblogs: true }] });
    });
    expect(screen.getByRole('menuitemcheckbox', { name: 'Notify about boosts' })).toHaveAttribute('aria-checked', 'true');
  });

  it('shares the save lock and confirmed values across two mounted columns', async () => {
    let resolve;
    const post = jest.fn(() => new Promise(yes => {
      resolve = yes;
    }));
    api.mockReturnValue({ post });
    const { store, intl } = setup();
    render(<Provider store={store}><NotificationSettings accountId='1' intl={intl} /></Provider>);
    const bells = screen.getAllByRole('button', { name: 'Notification settings' });
    expect(bells[0].getAttribute('aria-controls')).not.toBe(bells[1].getAttribute('aria-controls'));
    await act(async () => {
      fireEvent.click(bells[0]);
    });
    fireEvent.click(screen.getByRole('menuitemcheckbox', { name: 'Notify about boosts' }));
    await act(async () => {
      fireEvent.click(bells[1]);
    });
    const boosts = screen.getByRole('menuitemcheckbox', { name: 'Notify about boosts' });
    expect(boosts).toBeDisabled();
    fireEvent.click(boosts);
    expect(post).toHaveBeenCalledTimes(1);
    await act(async () => {
      resolve({ data: { ...base, notifying_reblogs: true } });
    });
    expect(boosts).toHaveAttribute('aria-checked', 'true');
    bells.forEach(bell => expect(bell).toHaveClass('active'));
  });

  it('updates the original account after unmount without writing to a new profile', async () => {
    let resolve;
    const post = jest.fn(() => new Promise(yes => {
      resolve = yes;
    }));
    api.mockReturnValue({ post });
    const { store, unmount, intl } = setup();
    await open();
    fireEvent.click(screen.getByRole('menuitemcheckbox', { name: 'Notify about boosts' }));
    unmount();
    await act(async () => {
      store.dispatch({ type: RELATIONSHIPS_FETCH_SUCCESS, relationships: [{ ...base, id: '2' }] });
    });
    render(<Provider store={store}><NotificationSettings accountId='2' intl={intl} /></Provider>);
    await act(async () => {
      resolve({ data: { ...base, notifying_reblogs: true } });
    });
    expect(store.getState().getIn(['relationships', '1', 'notifying_reblogs'])).toBe(true);
    expect(store.getState().getIn(['relationships', '2', 'notifying_reblogs'])).toBe(false);
    expect(post).toHaveBeenCalledTimes(1);
  });
});
