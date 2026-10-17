/* eslint-disable react/prop-types, react/jsx-no-bind */
import React from 'react';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { Router, Link, Route, withRouter } from 'react-router-dom';
import { createMemoryHistory } from 'history';
import { fromJS } from 'immutable';
import { EmbeddedRailsSettings } from '..';
import { getEmbeddedScreen, isFilterSettingsUrl, FILTER_SETTINGS_ROUTE } from '../registry';
import { WrappedSwitch, WrappedRoute } from '../../ui/util/react_router_helpers';
import { fetchFilters, FILTERS_FETCH_SUCCESS } from 'mastodon/actions/filters';
import compose from 'mastodon/reducers/compose';
import composers from 'mastodon/reducers/composers';

jest.mock('react-intl', () => ({
  injectIntl: Component => Component,
  defineMessages: messages => messages,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

jest.mock('mastodon/actions/filters', () => ({
  fetchFilters: jest.fn(() => ({ type: 'FILTERS_FETCH_REQUEST' })),
  FILTERS_FETCH_SUCCESS: 'FILTERS_FETCH_SUCCESS',
}));
jest.mock('../../ui/containers/bundle_container', () => ({ fetchComponent, children }) => children(fetchComponent()));
jest.mock('mastodon/components/icon', () => () => null);

const intl = { formatMessage: ({ defaultMessage }) => defaultMessage };
const dispatch = jest.fn();

function wrap(children, history = createMemoryHistory()) {
  return <Router history={history}>{children}</Router>;
}

function loadFrame(frame, { url = 'http://localhost/filters?embedded=1', marker = 'filters' } = {}) {
  const doc = document.implementation.createHTMLDocument();
  Object.defineProperty(doc, 'defaultView', { value: window });
  if (marker) doc.head.innerHTML = `<meta name="embedded-rails-settings" content="${marker}">`;
  Object.defineProperty(frame, 'contentWindow', { configurable: true, value: { location: { href: url, replace: jest.fn() }, confirm: jest.fn(() => true) } });
  Object.defineProperty(frame, 'contentDocument', { configurable: true, value: doc });
  fireEvent.load(frame);
}

beforeEach(() => {
  jest.useFakeTimers('modern');
  jest.clearAllMocks();
});
afterEach(() => jest.useRealTimers());

it('accepts only the fixed registry entry, regardless of URL-like names or query parameters', () => {
  expect(getEmbeddedScreen('https://evil.test')).toBeNull();
  expect(getEmbeddedScreen('__proto__')).toBeNull();
  expect(getEmbeddedScreen('constructor')).toBeNull();
  const history = createMemoryHistory({ initialEntries: ['/settings/filters?url=https://evil.test'] });
  render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />, history));
  expect(screen.getByTitle('Filter settings')).toHaveAttribute('src', '/filters?embedded=1');
  expect(screen.getByRole('link', { name: 'Open in a new tab' })).toHaveAttribute('href', '/filters');
  expect(screen.getByRole('link', { name: 'Open in a new tab' })).toHaveAttribute('rel', 'noopener noreferrer');
  expect(screen.getByRole('status')).toHaveTextContent('Loading settings');
});

it('allows only same-origin filter paths, including statuses and batch', () => {
  ['/filters', '/filters/new', '/filters/1/edit', '/filters/2/statuses', '/filters/2/statuses/batch'].forEach(path => {
    expect(isFilterSettingsUrl(new URL(path, 'http://localhost'), 'http://localhost')).toBe(true);
  });
  ['https://evil.test/filters', 'http://localhost/auth/sign_in', 'http://localhost/filters/../settings/profile', 'http://localhost/filters/2/other'].forEach(url => {
    expect(isFilterSettingsUrl(new URL(url), 'http://localhost')).toBe(false);
  });
});

it('coalesces trusted frame navigations into one existing fetchFilters call', () => {
  render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Filter settings');
  loadFrame(frame);
  loadFrame(frame, { url: 'http://localhost/filters/1/edit?embedded=1' });
  loadFrame(frame);
  expect(screen.queryByRole('status')).toBeNull();
  expect(dispatch).not.toHaveBeenCalled();
  act(() => jest.advanceTimersByTime(300));
  expect(fetchFilters).toHaveBeenCalledTimes(1);
  expect(dispatch).toHaveBeenCalledWith({ type: 'FILTERS_FETCH_REQUEST' });
  loadFrame(frame);
  act(() => jest.advanceTimersByTime(300));
  expect(fetchFilters).toHaveBeenCalledTimes(2);
});

it.each([
  { url: 'https://evil.test/filters?embedded=1' },
  { url: 'http://localhost/auth/sign_in' },
  { marker: null },
  { url: 'http://localhost/filters' },
])('shows the authentication/network fallback for an untrusted or blocked response %j', options => {
  render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />));
  loadFrame(screen.getByTitle('Filter settings'), options);
  expect(screen.getByRole('alert')).toHaveTextContent('sign in again');
  act(() => jest.advanceTimersByTime(300));
  expect(dispatch).not.toHaveBeenCalled();
});

it('times out, retries only the iframe, and ignores arbitrary messages', () => {
  const { unmount } = render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Filter settings');
  Object.defineProperty(frame, 'contentWindow', { configurable: true, value: { location: { replace: jest.fn() } } });
  act(() => jest.advanceTimersByTime(15000));
  expect(screen.getByRole('alert')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  expect(screen.getByTitle('Filter settings')).toBe(frame);
  expect(screen.getByRole('status')).toBeInTheDocument();
  fireEvent(window, new MessageEvent('message', { origin: 'http://localhost', data: { type: 'filters_changed', url: 'https://evil.test' } }));
  act(() => jest.advanceTimersByTime(300));
  expect(dispatch).not.toHaveBeenCalled();
  unmount();
  expect(jest.getTimerCount()).toBe(0);
});

it.each([[false, 'filters'], [true, 'filters'], [false, 'postingStyles'], [true, 'postingStyles']])('enters and leaves the wrapped route without remounting the WebUI or adjacent composers (multiColumn=%s, screen=%s)', (multiColumn, screenName) => {
  const route = screenName === 'filters' ? FILTER_SETTINGS_ROUTE : '/settings/posting-styles';
  const title = screenName === 'filters' ? 'Filter settings' : 'Posting style settings';
  const history = createMemoryHistory({ initialEntries: ['/timelines/tag/ruby'] });
  const mounts = jest.fn();
  const unmounts = jest.fn();
  class Composer extends React.Component {

    state = { text: 'draft', cw: 'spoiler' };
    componentDidMount() {
      mounts();
    }
    componentWillUnmount() {
      unmounts();
    }
    render() {
      return <input aria-label={this.props.name} value={this.state.text} onChange={e => this.setState({ text: e.target.value })} />;
    }

  }
  const Settings = props => <EmbeddedRailsSettings {...props} screen={screenName} dispatch={dispatch} intl={intl} returnTo='/timelines/tag/ruby' />;
  const fetchSettings = () => Settings;
  const renderHome = () => <p>Home</p>;
  const Routing = withRouter(({ location }) => (
    <WrappedSwitch multiColumn={multiColumn} location={location}>
      <WrappedRoute path={route} exact component={fetchSettings} />
      <Route render={renderHome} />
    </WrappedSwitch>
  ));
  const { container } = render(wrap(
    <div>
      <Composer name='first composer' /><Composer name='second composer' />
      <div data-testid='timeline' />
      <Link to={route}>Settings</Link>
      <Routing />
    </div>, history,
  ));
  const first = screen.getByLabelText('first composer');
  const timeline = screen.getByTestId('timeline');
  timeline.scrollTop = 120;
  fireEvent.change(first, { target: { value: 'unsaved edited draft' } });
  fireEvent.click(screen.getByText('Settings'));
  expect(container.querySelector('iframe')).toBeTruthy();
  loadFrame(screen.getByTitle(title), { url: `http://localhost${getEmbeddedScreen(screenName).embeddedPath}`, marker: screenName });
  fireEvent.click(screen.getByRole('link', { name: 'Back' }));
  expect(container.querySelector('iframe')).toBeNull();
  expect(history.location.pathname).toBe('/timelines/tag/ruby');
  expect(screen.getByLabelText('first composer')).toBe(first);
  expect(first).toHaveValue('unsaved edited draft');
  expect(screen.getByTestId('timeline')).toBe(timeline);
  expect(timeline.scrollTop).toBe(120);
  expect(mounts).toHaveBeenCalledTimes(2);
  expect(unmounts).not.toHaveBeenCalled();
  act(() => history.goForward());
  expect(screen.getByTitle(title)).toBeTruthy();
  expect(screen.getByLabelText('first composer')).toBe(first);
  expect(mounts).toHaveBeenCalledTimes(2);
  expect(screenName === 'filters' ? fetchFilters : fetchUserPostingStyles).toHaveBeenCalledTimes(1); // flushed on closing
});

it('leaves primary and portable composer text, CW, attachments and edit state unchanged on filter refresh', () => {
  const primary = fromJS({ text: 'primary', spoiler_text: 'CW', media_attachments: [{ id: 'media1' }], id: 'editing1' });
  const portable = fromJS({ byId: {
    one: { text: 'draft1', spoiler_text: 'CW1', media_attachments: [{ id: 'media2' }], id: 'editing2' },
    two: { text: 'draft2', spoiler_text: 'CW2', media_attachments: [{ id: 'media3' }], id: 'editing3' },
  } });
  const action = { type: FILTERS_FETCH_SUCCESS, filters: [] };
  expect(compose(primary, action)).toBe(primary);
  expect(composers(portable, action)).toBe(portable);
});

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => {
    resolve = yes; reject = no;
  });
  return { promise, resolve, reject };
};

it.each([
  ['create', '/filters?embedded=1', null],
  ['update', '/filters/1?embedded=1', 'put'],
  ['destroy', '/filters/1?embedded=1', 'delete'],
  ['batch', '/filters/1/statuses/batch?embedded=1', null],
])('reconciles %s after its response even when closed before commit/redirect', async (kind, path, method) => {
  const request = deferred();
  window.fetch = jest.fn(() => request.promise);
  const { unmount } = render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Filter settings');
  loadFrame(frame);
  act(() => jest.advanceTimersByTime(300));
  dispatch.mockClear(); fetchFilters.mockClear();
  frame.contentDocument.body.innerHTML = `<form method="post" action="${path}"><input name="authenticity_token" value="token"><input name="_method" value="${method || 'post'}"><button type="submit" name="remove" value="yes">Save</button></form>`;
  fireEvent.submit(frame.contentDocument.querySelector('form'));
  expect(window.fetch).toHaveBeenCalledTimes(1);
  expect(window.fetch.mock.calls[0][1].body.get('_method')).toBe(method || 'post');
  expect(window.fetch.mock.calls[0][1].body.get('authenticity_token')).toBe('token');
  expect(window.fetch.mock.calls[0][1].body.get('remove')).toBe('yes');
  unmount();
  expect(fetchFilters).not.toHaveBeenCalled();
  await act(async () => {
    request.resolve({ ok: true, redirected: true, url: 'http://localhost/filters?embedded=1' });
    await request.promise;
  });
  expect(fetchFilters).toHaveBeenCalledTimes(1);
  expect(dispatch).toHaveBeenCalledWith({ type: 'FILTERS_FETCH_REQUEST' });
});

it('reconciles a completed save before the redirect load, and suppresses duplicate submits', async () => {
  const request = deferred();
  window.fetch = jest.fn(() => request.promise);
  const { unmount } = render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Filter settings');
  loadFrame(frame);
  act(() => jest.advanceTimersByTime(300));
  fetchFilters.mockClear();
  frame.contentDocument.body.innerHTML = '<form method="post" action="/filters?embedded=1"><button type="submit">Save</button></form>';
  fireEvent.submit(frame.contentDocument.querySelector('form'));
  fireEvent.submit(frame.contentDocument.querySelector('form'));
  expect(window.fetch).toHaveBeenCalledTimes(1);
  await act(async () => {
    request.resolve({ ok: true, redirected: true, url: 'http://localhost/filters?embedded=1' });
    await request.promise;
  });
  expect(fetchFilters).toHaveBeenCalledTimes(1);
  expect(frame.contentWindow.location.replace).toHaveBeenCalledWith('http://localhost/filters?embedded=1');
  // There has been no redirect load event, and leaving cannot lose the refresh.
  unmount();
  expect(fetchFilters).toHaveBeenCalledTimes(1);
});

it('restarts a bounded timeout for subsequent link navigations without adding child history', () => {
  render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Filter settings');
  loadFrame(frame);
  frame.contentDocument.body.innerHTML = '<a href="/filters/1/edit?embedded=1">Edit</a>';
  fireEvent.click(frame.contentDocument.querySelector('a'));
  expect(frame.contentWindow.location.replace).toHaveBeenCalledWith('http://localhost/filters/1/edit?embedded=1');
  expect(screen.getByRole('status')).toBeInTheDocument();
  act(() => jest.advanceTimersByTime(15000));
  expect(screen.getByRole('alert')).toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Try again' })).not.toBeDisabled();
});

it('keeps the pending save alive after a UI timeout, then refreshes and recovers', async () => {
  const request = deferred(); window.fetch = jest.fn(() => request.promise);
  render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Filter settings'); loadFrame(frame);
  act(() => jest.advanceTimersByTime(300)); fetchFilters.mockClear();
  frame.contentDocument.body.innerHTML = '<form method="post" action="/filters?embedded=1"></form>';
  fireEvent.submit(frame.contentDocument.querySelector('form'));
  act(() => jest.advanceTimersByTime(15000));
  expect(screen.getByRole('button', { name: 'Try again' })).toBeDisabled();
  expect(fetchFilters).not.toHaveBeenCalled();
  await act(async () => {
    request.resolve({ ok: true, redirected: true, url: 'http://localhost/filters?embedded=1' });
    await request.promise;
  });
  expect(fetchFilters).toHaveBeenCalledTimes(1);
  expect(frame.contentWindow.location.replace).toHaveBeenCalledTimes(1);
});

it('reuses an invalid Rails form without navigating away and keeps the next submit usable', async () => {
  window.fetch = jest.fn().mockResolvedValue({ ok: true, redirected: false, url: 'http://localhost/filters?embedded=1', text: async () => '<html><head><meta name="embedded-rails-settings" content="filters"></head><body><main class="embedded-settings"><p class="error">Invalid title</p><form method="post" action="/filters?embedded=1"><input name="custom_filter[title]" value=""></form></main></body></html>' });
  render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Filter settings'); loadFrame(frame, { url: 'http://localhost/filters/new?embedded=1' });
  frame.contentDocument.body.innerHTML = '<main class="embedded-settings"><form method="post" action="/filters?embedded=1"></form></main>';
  await act(async () => {
    fireEvent.submit(frame.contentDocument.querySelector('form'));
  });
  expect(frame.contentDocument.querySelector('.error')).toHaveTextContent('Invalid title');
  expect(frame.contentWindow.location.replace).not.toHaveBeenCalled();
  await act(async () => {
    fireEvent.submit(frame.contentDocument.querySelector('form'));
  });
  expect(window.fetch).toHaveBeenCalledTimes(2);
});

it('refreshes once on network failure or session expiry, and keeps login out of the frame', async () => {
  window.fetch = jest.fn().mockResolvedValue({ ok: true, redirected: true, url: 'http://localhost/auth/sign_in' });
  render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Filter settings'); loadFrame(frame);
  act(() => jest.advanceTimersByTime(300)); fetchFilters.mockClear();
  frame.contentDocument.body.innerHTML = '<form method="post" action="/filters?embedded=1"></form>';
  await act(async () => {
    fireEvent.submit(frame.contentDocument.querySelector('form'));
  });
  expect(screen.getByRole('alert')).toBeInTheDocument();
  expect(frame.contentWindow.location.replace).not.toHaveBeenCalled();
  expect(fetchFilters).toHaveBeenCalledTimes(1);
});


it('binds trusted DOM readiness before full load and ignores that document’s later load', () => {
  render(wrap(<EmbeddedRailsSettings dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Filter settings');
  loadFrame(frame);
  // Rebind a fresh document through the child ready event, not the full load.
  const doc = document.implementation.createHTMLDocument();
  doc.head.innerHTML = '<meta name="embedded-rails-settings" content="filters">';
  Object.defineProperty(frame, 'contentDocument', { configurable: true, value: doc });
  fireEvent(frame, new Event('embedded-settings:ready'));
  expect(frame).toHaveAttribute('aria-busy', 'false');
  doc.body.innerHTML = '<a href="http://localhost/filters/new?embedded=1">New</a>';
  doc.querySelector('a').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  expect(frame).toHaveAttribute('aria-busy', 'true');
  fireEvent.load(frame); // a late load from the old document must not clear this timeout
  act(() => jest.advanceTimersByTime(15000));
  expect(screen.getByRole('alert')).toBeInTheDocument();
});

jest.mock('mastodon/initial_state', () => ({ isAdministrator: true }));
jest.mock('mastodon/actions/user_posting_styles', () => ({
  fetchUserPostingStyles: jest.fn(() => ({ type: 'CATALOG_REFRESH' })),
}));
const { fetchUserPostingStyles } = require('mastodon/actions/user_posting_styles');

it.each([
  ['create', '/settings/user_posting_contexts?embedded=1', null],
  ['update', '/settings/user_posting_contexts/1?embedded=1', 'patch'],
  ['duplicate', '/settings/user_posting_contexts/1/duplicate?embedded=1', null],
  ['delete', '/settings/user_posting_contexts/1?embedded=1', 'delete'],
  ['release', '/settings/user_posting_context_assignments/1/release?embedded=1', null],
  ['decline', '/settings/user_posting_context_assignments/1/decline?embedded=1', null],
])('refreshes posting styles after %s completes following departure, separately from passive load', async (kind, path, method) => {
  const request = deferred(); window.fetch = jest.fn(() => request.promise);
  const { unmount } = render(wrap(<EmbeddedRailsSettings screen='postingStyles' dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Posting style settings');
  loadFrame(frame, { url: 'http://localhost/settings/user_posting_contexts?embedded=1', marker: 'postingStyles' });
  act(() => jest.advanceTimersByTime(300));
  expect(fetchUserPostingStyles).toHaveBeenCalledWith({ force: true });
  fetchUserPostingStyles.mockClear();
  frame.contentDocument.body.innerHTML = `<form method="post" action="${path}"><input name="_method" value="${method || 'post'}"></form>`;
  fireEvent.submit(frame.contentDocument.querySelector('form'));
  unmount();
  expect(fetchUserPostingStyles).not.toHaveBeenCalled();
  await act(async () => {
    request.resolve({ ok: true, redirected: true, url: 'http://localhost/settings/user_posting_contexts?embedded=1' });
    await request.promise;
  });
  expect(fetchUserPostingStyles).toHaveBeenCalledTimes(1);
  expect(fetchFilters).not.toHaveBeenCalled();
});

it.each([200, 409, 422])('keeps Rails validation/conflict HTML %s inside the existing protected posting styles document', async status => {
  window.fetch = jest.fn().mockResolvedValue({ ok: status === 200, status, redirected: false, url: 'http://localhost/settings/user_posting_contexts/1?embedded=1', text: async () => '<html><head><meta name="embedded-rails-settings" content="postingStyles"></head><body><main class="embedded-settings"><p class="error">Please review the style</p><form method="post" action="/settings/user_posting_contexts/1?embedded=1"><input name="_method" value="patch"></form></main></body></html>' });
  render(wrap(<EmbeddedRailsSettings screen='postingStyles' dispatch={dispatch} intl={intl} />));
  const frame = screen.getByTitle('Posting style settings');
  loadFrame(frame, { url: 'http://localhost/settings/user_posting_contexts/1/edit?embedded=1', marker: 'postingStyles' });
  const doc = frame.contentDocument; const head = doc.head;
  doc.body.innerHTML = '<main class="embedded-settings"><form method="post" action="/settings/user_posting_contexts/1?embedded=1"><input name="_method" value="patch"></form></main>';
  const rendered = jest.fn(); doc.addEventListener('embedded-settings:render', rendered);
  await act(async () => fireEvent.submit(doc.querySelector('form')));
  expect(doc.querySelector('.error').textContent).toBe('Please review the style');
  expect(doc.head).toBe(head);
  expect(rendered).toHaveBeenCalledTimes(1);
  expect(frame.contentWindow.location.replace).not.toHaveBeenCalled();
  expect(screen.queryByRole('alert')).toBeNull();
  await act(async () => fireEvent.submit(doc.querySelector('form')));
  expect(window.fetch).toHaveBeenCalledTimes(2);
});

it('rejects the other screen marker and routes before refreshing or binding', () => {
  render(wrap(<EmbeddedRailsSettings screen='postingStyles' dispatch={dispatch} intl={intl} />));
  loadFrame(screen.getByTitle('Posting style settings'), { url: 'http://localhost/filters?embedded=1' });
  act(() => jest.advanceTimersByTime(300));
  expect(screen.getByRole('alert')).toBeTruthy();
  expect(fetchUserPostingStyles).not.toHaveBeenCalled();
});

it('preserves complete selected snapshots and drafts in primary and portable composers during catalog replacement/deletion/failure', () => {
  const draft = {
    text: 'Keep this draft', spoiler_text: 'CW', media_attachments: [{ id: 'attachment' }],
    poll: { options: ['A', 'B'], expires_in: 3600 }, language: 'ja', privacy: 'private', id: 'editing',
    userPostingStyle: { selectedId: '1', snapshot: { id: '1', name: 'Previously applied', revision: 1 }, selectionOrigin: 'manual', defaultsSettledSurface: 'hashtag:books', overrides: { privacy: true } },
  };
  const primary = fromJS(draft);
  const portable = fromJS({ byId: { one: draft, two: { ...draft, text: 'Separate draft' } } });
  for (const action of [
    { type: 'USER_POSTING_STYLES_FETCH_REQUEST', requestId: 1 },
    { type: 'USER_POSTING_STYLES_FETCH_SUCCESS', requestId: 1, styles: [] },
    { type: 'USER_POSTING_STYLES_FETCH_FAIL', requestId: 1 },
  ]) {
    expect(compose(primary, action)).toBe(primary);
    expect(composers(portable, action)).toBe(portable);
  }
});

it('keeps duplicate submission locked after leaving and reentering during a pending save', async () => {
  const request = deferred(); window.fetch = jest.fn(() => request.promise);
  let view = render(wrap(<EmbeddedRailsSettings screen='postingStyles' dispatch={dispatch} intl={intl} />));
  let frame = screen.getByTitle('Posting style settings');
  loadFrame(frame, { url: 'http://localhost/settings/user_posting_contexts?embedded=1', marker: 'postingStyles' });
  frame.contentDocument.body.innerHTML = '<form method="post" action="/settings/user_posting_contexts?embedded=1"></form>';
  fireEvent.submit(frame.contentDocument.querySelector('form'));
  view.unmount();
  view = render(wrap(<EmbeddedRailsSettings screen='postingStyles' dispatch={dispatch} intl={intl} />));
  frame = screen.getByTitle('Posting style settings');
  loadFrame(frame, { url: 'http://localhost/settings/user_posting_contexts?embedded=1', marker: 'postingStyles' });
  frame.contentDocument.body.innerHTML = '<form method="post" action="/settings/user_posting_contexts?embedded=1"></form>';
  fireEvent.submit(frame.contentDocument.querySelector('form'));
  expect(window.fetch).toHaveBeenCalledTimes(1);
  expect(frame).toHaveAttribute('aria-busy', 'true');
  await act(async () => {
    request.resolve({ ok: true, redirected: true, url: 'http://localhost/settings/user_posting_contexts?embedded=1' });
    await request.promise;
  });
  expect(frame).toHaveAttribute('aria-busy', 'false');
  view.unmount();
});
