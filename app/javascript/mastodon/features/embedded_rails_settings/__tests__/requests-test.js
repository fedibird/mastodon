import { bindFilterSettingsNavigation, submitFilterSettings } from '../requests';
import { fetchFilters } from 'mastodon/actions/filters';

jest.mock('mastodon/actions/filters', () => ({ fetchFilters: jest.fn(() => ({ type: 'FILTERS_FETCH_REQUEST' })) }));

beforeEach(() => jest.clearAllMocks());

it('handles confirmed UJS delete links with the existing CSRF token and no native navigation', () => {
  const doc = document.implementation.createHTMLDocument();
  doc.head.innerHTML = '<meta name="csrf-token" content="existing-token">';
  doc.body.innerHTML = '<a href="http://localhost/filters/1?embedded=1" data-method="delete" data-confirm="Really?">Delete</a>';
  const frame = { contentDocument: doc, contentWindow: { location: { href: 'http://localhost/filters?embedded=1' }, confirm: jest.fn(() => false) } };
  const onSubmit = jest.fn(); const onNavigate = jest.fn();
  const unbind = bindFilterSettingsNavigation(frame, { onSubmit, onNavigate });
  doc.querySelector('a').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  expect(onSubmit).not.toHaveBeenCalled();
  frame.contentWindow.confirm.mockReturnValue(true);
  doc.querySelector('a').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  expect(onSubmit).toHaveBeenCalledTimes(1);
  expect(onSubmit.mock.calls[0][1].get('_method')).toBe('delete');
  expect(onSubmit.mock.calls[0][1].get('authenticity_token')).toBe('existing-token');
  expect(onNavigate).not.toHaveBeenCalled();
  unbind();
});

it('leaves external/new-tab links, modifier clicks and cocoon hash actions alone', () => {
  const doc = document.implementation.createHTMLDocument();
  const frame = { contentDocument: doc, contentWindow: { location: { href: 'http://localhost/filters?embedded=1' } } };
  const onSubmit = jest.fn(); const onNavigate = jest.fn();
  const unbind = bindFilterSettingsNavigation(frame, { onSubmit, onNavigate });
  ['https://evil.test/filters?embedded=1', '#', '/auth/sign_in'].forEach(href => {
    doc.body.innerHTML = `<a href="${href}">Link</a>`;
    doc.querySelector('a').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  });
  doc.body.innerHTML = '<a href="http://localhost/filters/new?embedded=1" target="_blank">Link</a>';
  doc.querySelector('a').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  doc.querySelector('a').removeAttribute('target');
  doc.querySelector('a').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, ctrlKey: true }));
  expect(onNavigate).not.toHaveBeenCalled(); expect(onSubmit).not.toHaveBeenCalled();
  unbind();
});

it('reconciles once on an ambiguous network failure and propagates the failure', async () => {
  const error = new Error('connection lost');
  window.fetch = jest.fn().mockRejectedValue(error);
  const dispatch = jest.fn();
  await expect(submitFilterSettings(new URL('http://localhost/filters?embedded=1'), new FormData(), dispatch)).rejects.toBe(error);
  expect(fetchFilters).toHaveBeenCalledTimes(1);
  expect(dispatch).toHaveBeenCalledWith({ type: 'FILTERS_FETCH_REQUEST' });
});

it('rejects arbitrary mutation destinations without a fetch or refresh', async () => {
  window.fetch = jest.fn(); const dispatch = jest.fn();
  await expect(submitFilterSettings(new URL('https://evil.test/filters?embedded=1'), new FormData(), dispatch)).rejects.toThrow();
  expect(window.fetch).not.toHaveBeenCalled(); expect(dispatch).not.toHaveBeenCalled();
});

jest.mock('mastodon/actions/user_posting_styles', () => ({ fetchUserPostingStyles: jest.fn(() => ({ type: 'CATALOG_REFRESH' })) }));
const { submitEmbeddedSettings, bindEmbeddedSettingsNavigation } = require('../requests');
const { fetchUserPostingStyles } = require('mastodon/actions/user_posting_styles');

it('reconciles posting styles once on ambiguous failure without resending the mutation', async () => {
  const error = new Error('lost after commit'); window.fetch = jest.fn().mockRejectedValue(error);
  const dispatch = jest.fn();
  await expect(submitEmbeddedSettings('postingStyles', new URL('http://localhost/settings/user_posting_contexts?embedded=1'), new FormData(), dispatch)).rejects.toBe(error);
  expect(window.fetch).toHaveBeenCalledTimes(1);
  expect(fetchUserPostingStyles).toHaveBeenCalledTimes(1);
  expect(fetchUserPostingStyles).toHaveBeenCalledWith({ force: true });
  expect(fetchFilters).not.toHaveBeenCalled();
});

it('blocks unexpected forms, but leaves Rails JSON preview fetches independent of HTML submission', async () => {
  const doc = document.implementation.createHTMLDocument();
  const frame = { contentDocument: doc, contentWindow: { location: { href: 'http://localhost/settings/user_posting_contexts?embedded=1' } } };
  const onSubmit = jest.fn(), onNavigate = jest.fn(), onInvalid = jest.fn();
  bindEmbeddedSettingsNavigation('postingStyles', frame, { onSubmit, onNavigate, onInvalid });
  for (const action of ['/filters?embedded=1', '/settings/preferences', '/settings/user_posting_contexts/preview?embedded=1']) {
    doc.body.innerHTML = `<form action="${action}" method="post"></form>`;
    const event = new Event('submit', { bubbles: true, cancelable: true });
    doc.querySelector('form').dispatchEvent(event);
    expect(event.defaultPrevented).toBe(true);
  }
  expect(onInvalid).toHaveBeenCalledTimes(3);
  expect(onSubmit).not.toHaveBeenCalled();
});
