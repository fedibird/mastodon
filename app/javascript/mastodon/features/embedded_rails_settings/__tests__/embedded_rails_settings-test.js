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
  if (marker) doc.head.innerHTML = `<meta name="embedded-rails-settings" content="${marker}">`;
  Object.defineProperty(frame, 'contentWindow', { configurable: true, value: { location: { href: url } } });
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
  act(() => jest.advanceTimersByTime(15000));
  expect(screen.getByRole('alert')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  expect(screen.getByTitle('Filter settings')).not.toBe(frame);
  expect(screen.getByRole('status')).toBeInTheDocument();
  fireEvent(window, new MessageEvent('message', { origin: 'http://localhost', data: { type: 'filters_changed', url: 'https://evil.test' } }));
  act(() => jest.advanceTimersByTime(300));
  expect(dispatch).not.toHaveBeenCalled();
  unmount();
  expect(jest.getTimerCount()).toBe(0);
});

it.each([false, true])('enters and leaves the wrapped route without remounting the WebUI or adjacent composers (multiColumn=%s)', multiColumn => {
  const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
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
  const Settings = props => <EmbeddedRailsSettings {...props} dispatch={dispatch} intl={intl} />;
  const fetchSettings = () => Settings;
  const renderHome = () => <p>Home</p>;
  const Routing = withRouter(({ location }) => (
    <WrappedSwitch multiColumn={multiColumn} location={location}>
      <WrappedRoute path={FILTER_SETTINGS_ROUTE} exact component={fetchSettings} />
      <Route render={renderHome} />
    </WrappedSwitch>
  ));
  const { container } = render(wrap(
    <div>
      <Composer name='first composer' /><Composer name='second composer' />
      <div data-testid='timeline' />
      <Link to={FILTER_SETTINGS_ROUTE}>Settings</Link>
      <Routing />
    </div>, history,
  ));
  const first = screen.getByLabelText('first composer');
  const timeline = screen.getByTestId('timeline');
  timeline.scrollTop = 120;
  fireEvent.change(first, { target: { value: 'unsaved edited draft' } });
  fireEvent.click(screen.getByText('Settings'));
  expect(container.querySelector('iframe')).toBeTruthy();
  loadFrame(screen.getByTitle('Filter settings'));
  fireEvent.click(screen.getByRole('link', { name: 'Back' }));
  expect(container.querySelector('iframe')).toBeNull();
  expect(screen.getByLabelText('first composer')).toBe(first);
  expect(first).toHaveValue('unsaved edited draft');
  expect(screen.getByTestId('timeline')).toBe(timeline);
  expect(timeline.scrollTop).toBe(120);
  expect(mounts).toHaveBeenCalledTimes(2);
  expect(unmounts).not.toHaveBeenCalled();
  expect(fetchFilters).toHaveBeenCalledTimes(1); // flushed on closing
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
