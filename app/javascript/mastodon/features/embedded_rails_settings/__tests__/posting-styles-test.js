/* eslint-disable react/prop-types, react/jsx-no-bind */
import React from 'react';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { EmbeddedRailsSettings } from '..';
import { isPostingStylesSettingsUrl, isEmbeddedSettingsUrl } from '../registry';
import { bindEmbeddedSettingsNavigation, submitEmbeddedSettings } from '../requests';
import { fetchUserPostingStyles } from 'mastodon/actions/user_posting_styles';
import { trackSettingsOrigin, safeReactReturnTo } from '../navigation';
import * as initialState from 'mastodon/initial_state';

jest.mock('react-intl', () => ({ injectIntl: Component => Component, defineMessages: messages => messages, FormattedMessage: ({ defaultMessage }) => defaultMessage }));
jest.mock('mastodon/initial_state', () => ({ __esModule: true, isAdministrator: true, defaultColumnWidth: 350 }));
jest.mock('mastodon/actions/user_posting_styles', () => ({ fetchUserPostingStyles: jest.fn(() => ({ type: 'STYLES_REFRESH' })) }));
jest.mock('mastodon/actions/filters', () => ({ fetchFilters: jest.fn(() => ({ type: 'FILTERS_REFRESH' })) }));
jest.mock('mastodon/components/icon', () => () => null);

const origin = 'http://localhost';
const base = '/settings/user_posting_contexts';
const assignments = '/settings/user_posting_context_assignments';
const check = (path, method = 'GET', preview = false) => isPostingStylesSettingsUrl(new URL(path, origin), origin, method, preview);
const defer = () => {
  let resolve; let reject;
  const promise = new Promise((yes, no) => {
    resolve = yes; reject = no;
  });
  return { promise, resolve, reject };
};
const url = path => new URL(`${path}?embedded=1`, origin);
const intl = { formatMessage: ({ defaultMessage }) => defaultMessage };
const mount = dispatch => render(<MemoryRouter><EmbeddedRailsSettings screen='postingStyles' dispatch={dispatch} intl={intl} /></MemoryRouter>);
const load = (frame, path = base, marker = 'postingStyles') => {
  const doc = document.implementation.createHTMLDocument();
  doc.head.innerHTML = `<meta name="embedded-rails-settings" content="${marker}"><meta name="csrf-token" content="token">`;
  doc.body.innerHTML = `<main class="embedded-settings"><form method="post" action="${origin}${base}?embedded=1"><input name="user_posting_context[name]" value="Notes"><button type="submit">Save</button></form></main>`;
  Object.defineProperty(doc, 'defaultView', { value: window });
  Object.defineProperty(frame, 'contentDocument', { configurable: true, value: doc });
  Object.defineProperty(frame, 'contentWindow', { configurable: true, value: { location: { href: url(path).href, replace: jest.fn() } } });
  fireEvent.load(frame);
  return doc;
};
beforeEach(() => {
  initialState.isAdministrator = true; jest.clearAllMocks(); jest.useFakeTimers('modern');
});
afterEach(() => jest.useRealTimers());

it.each([[base, 'GET'], [`${base}/new`, 'GET'], [`${base}/9223372036854775807/edit`, 'GET'], [`${base}/1/confirm_destroy`, 'GET'], [base, 'POST'], [`${base}/1`, 'PATCH'], [`${base}/1`, 'DELETE'], [`${base}/1/duplicate`, 'POST'], [assignments, 'GET'], [`${assignments}/1/release`, 'POST'], [`${assignments}/1/decline`, 'POST']])('allows the real route %s %s only', (path, method) => expect(check(path, method)).toBe(true));
it.each([`${base}/1`, `${base}/01/edit`, `${base}/0/edit`, `${base}/9223372036854775808/edit`, `${base}/1/duplicate`, `${base}/preview`, `${base}/1/edit?return_to=https://evil.test`, `${base}?embedded=0`, `${base}?embedded=1&embedded=1`, `${base}?page=2`, `${assignments}?page=-1`, `${assignments}?page=01`, `${assignments}?page=2147483648`, `${assignments}?user_posting_context_id=99999999999999999999999`, '/filters?embedded=1', '/auth/sign_in?embedded=1', 'https://evil.test/settings/user_posting_contexts', `${base}/%31/edit`])('rejects forbidden URLs/queries: %s', path => expect(check(path)).toBe(false));
it('allows assignment paging and explicit JSON preview without allowing iframe preview navigation or HTML submission', async () => {
  expect(check(`${assignments}?page=2&user_posting_context_id=1&embedded=1`)).toBe(true);
  expect(check(`${base}/preview`, 'POST', true)).toBe(true);
  expect(check(`${base}/preview`, 'POST')).toBe(false);
  window.fetch = jest.fn();
  await expect(submitEmbeddedSettings('postingStyles', url(`${base}/preview`), new FormData(), jest.fn())).rejects.toThrow();
  expect(window.fetch).not.toHaveBeenCalled();
  expect(isEmbeddedSettingsUrl('filters', url(base), origin)).toBe(false);
});

it('refreshes only after mutation completion, survives departure, and blocks duplicate pending saves across remount', async () => {
  const pending = defer(); window.fetch = jest.fn(() => pending.promise);
  const dispatch = jest.fn(); const body = new FormData();
  const first = submitEmbeddedSettings('postingStyles', url(base), body, dispatch);
  expect(fetchUserPostingStyles).not.toHaveBeenCalled();
  await expect(submitEmbeddedSettings('postingStyles', url(base), body, dispatch)).rejects.toThrow('pending');
  expect(window.fetch).toHaveBeenCalledTimes(1);
  const view = mount(dispatch); const frame = screen.getByTitle('Posting style settings'); load(frame);
  expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull();
  view.unmount();
  pending.resolve({ ok: true }); await first;
  expect(fetchUserPostingStyles).toHaveBeenCalledWith({ force: true });
  expect(dispatch).toHaveBeenCalledWith({ type: 'STYLES_REFRESH' });
});

it('reconciles an ambiguous failure once and permits a deliberate next save', async () => {
  window.fetch = jest.fn().mockRejectedValueOnce(new Error('lost')).mockResolvedValueOnce({ ok: true });
  const dispatch = jest.fn();
  await expect(submitEmbeddedSettings('postingStyles', url(base), new FormData(), dispatch)).rejects.toThrow('lost');
  expect(fetchUserPostingStyles).toHaveBeenCalledTimes(1);
  await submitEmbeddedSettings('postingStyles', url(base), new FormData(), dispatch);
  expect(window.fetch).toHaveBeenCalledTimes(2);
  expect(fetchUserPostingStyles).toHaveBeenCalledTimes(2);
});

it.each([200, 409, 422])('renders protected validation/conflict HTML %s without navigating or dropping the form', async status => {
  const dispatch = jest.fn(); mount(dispatch);
  const frame = screen.getByTitle('Posting style settings'); const doc = load(frame, `${base}/new`);
  const oldMain = doc.querySelector('main');
  const disposing = jest.fn(() => expect(doc.querySelector('main')).toBe(oldMain));
  doc.addEventListener('embedded-settings:before-render', disposing);
  window.fetch = jest.fn().mockResolvedValue({ ok: status === 200, status, url: url(base).href, redirected: false, headers: new Headers({ 'content-type': 'text/html' }), text: () => Promise.resolve('<head><meta name="embedded-rails-settings" content="postingStyles"></head><main class="embedded-settings"><form><input name="lock_version" value="7"><p>Validation or conflict</p></form></main>') });
  await act(async () => {
    doc.querySelector('form').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  });
  expect(disposing).toHaveBeenCalledTimes(1);
  expect(doc.body.textContent).toContain('Validation or conflict');
  expect(doc.querySelector('input').value).toBe('7');
  expect(frame.contentWindow.location.replace).not.toHaveBeenCalled();
  expect(screen.queryByRole('alert')).toBeNull();
});

it('rejects a cross-screen marker or login load; non-administrators mount no iframe', () => {
  const view = mount(jest.fn()); load(screen.getByTitle('Posting style settings'), base, 'filters');
  expect(screen.getByRole('alert')).toBeTruthy(); view.unmount();
  initialState.isAdministrator = false;
  mount(jest.fn()); expect(document.querySelector('iframe')).toBeNull();
});

it('retains observed Back/Forward origins and refuses recursive return paths for both screens', () => {
  const source = { pathname: '/timelines/home', key: 'home' };
  const location = { pathname: '/settings/posting-styles', key: 'styles' };
  const state = trackSettingsOrigin({ lastLocation: source, origins: {} }, location, 'PUSH');
  expect(state.origins.styles).toBe('/timelines/home');
  expect(trackSettingsOrigin(state, source, 'POP').origins.styles).toBe('/timelines/home');
  expect(safeReactReturnTo(location)).toBeNull();
});

it('intercepts real forms but leaves AJAX preview fetches alone and blocks forbidden forms', () => {
  const doc = document.implementation.createHTMLDocument();
  doc.body.innerHTML = `<form method="post" action="${url(`${base}/1`).href}"><input name="_method" value="patch"><input name="authenticity_token" value="token"></form>`;
  const frame = { contentDocument: doc, contentWindow: { location: { href: url(`${base}/1/edit`).href } } };
  const onSubmit = jest.fn(); const onReject = jest.fn();
  const unbind = bindEmbeddedSettingsNavigation('postingStyles', frame, { onNavigate: jest.fn(), onSubmit, onReject });
  doc.querySelector('form').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  expect(onSubmit.mock.calls[0][1].get('_method')).toBe('patch');
  doc.querySelector('form').action = '/auth/sign_in';
  const event = new Event('submit', { bubbles: true, cancelable: true }); doc.querySelector('form').dispatchEvent(event);
  expect(event.defaultPrevented).toBe(true); expect(onReject).toHaveBeenCalledTimes(1);
  unbind();
});

it('does not detach form navigation when ready and load fire for the same document', async () => {
  mount(jest.fn()); const frame = screen.getByTitle('Posting style settings');
  const doc = load(frame); fireEvent.load(frame);
  window.fetch = jest.fn().mockResolvedValue({ ok: true, status: 200, redirected: true, url: url(base).href, headers: new Headers({ 'content-type': 'text/html' }) });
  await act(async () => {
    doc.querySelector('form').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  });
  expect(window.fetch).toHaveBeenCalledTimes(1);
  expect(frame.contentWindow.location.replace).toHaveBeenCalledWith(url(base).href);
});
