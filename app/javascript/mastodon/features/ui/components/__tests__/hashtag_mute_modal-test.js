import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('mastodon/api', () => () => ({
  get: (...args) => mockGet(...args),
  post: (...args) => mockPost(...args),
  put: (...args) => mockPut(...args),
  delete: (...args) => mockDelete(...args),
}));

jest.mock('react-intl', () => {
  const interpolate = (defaultMessage, values) => {
    if (!values) {
      return defaultMessage;
    }

    return defaultMessage.split(/\{(\w+)\}/g).map((part, index) => (
      index % 2 === 1 ? values[part] : part
    )).join('');
  };
  const intl = {
    locale: 'en',
    formatMessage: ({ defaultMessage }, values) => interpolate(defaultMessage, values),
    formatTime: () => '3:00 PM',
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => interpolate(defaultMessage, values),
  };
});

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import filtersReducer from 'mastodon/reducers/filters';
import filterClockReducer from 'mastodon/reducers/filter_clock';
import emojiMutesReducer from 'mastodon/reducers/emoji_mutes';
import HashtagMuteModal from '../hashtag_mute_modal';

function reducer(state = fromJS({ filters: {}, filterClock: 0 }), action) {
  if (action.type === 'MODAL_CLOSE') {
    return state.set('closed', true);
  }

  const emojiType = action && typeof action.type === 'string' && action.type.indexOf('EMOJI_MUTES_') === 0;
  let next = state;

  if (emojiType || next.has('emojiMutes')) {
    next = next.set('emojiMutes', emojiMutesReducer(next.get('emojiMutes'), action));
  }

  return next
    .set('filters', filtersReducer(next.get('filters'), action))
    .set('filterClock', filterClockReducer(next.get('filterClock'), action));
}

function renderModal(hashtag = '番組', emojiMutes) {
  const initial = emojiMutes ? fromJS({ filters: {}, filterClock: 0, emojiMutes }) : undefined;
  const store = createStore(reducer, initial, applyMiddleware(thunk));

  render(
    <Provider store={store}>
      <MemoryRouter>
        <HashtagMuteModal hashtag={hashtag} />
      </MemoryRouter>
    </Provider>,
  );

  return store;
}

describe('HashtagMuteModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockGet.mockResolvedValue({ data: [] });
    mockPost.mockResolvedValue({ data: { id: '9', title: '#番組', context: ['home'], filter_action: 'hide', expires_at: null, keywords: [], statuses: [], tags: [{ id: '1', name: '番組' }] } });
    mockPut.mockResolvedValue({ data: { id: '9', title: '#番組', context: ['home'], filter_action: 'hide', expires_at: null, keywords: [], statuses: [], tags: [{ id: '1', name: '番組' }] } });
    mockDelete.mockResolvedValue({ data: {} });
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('confirms the tag, the default indefinite duration, and every place before saving', async () => {
    renderModal();

    const duration = await screen.findByLabelText(/Duration/);
    const values = Array.from(duration.options).map(option => option.value);

    expect(values).toEqual(['0', '300', '1800', '3600', '7200', '10800', '21600', '86400', '259200', '604800']);
    expect(duration).toHaveValue('0');
    expect(screen.getByText('Home and lists')).toBeTruthy();
    expect(screen.getByText('Notifications')).toBeTruthy();
    expect(screen.getByText('Public and other timelines')).toBeTruthy();
    expect(screen.getByText('Conversations')).toBeTruthy();
    expect(screen.getByText('Profiles')).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Change where this applies' })).toHaveAttribute('href', '/settings/filters');

    await waitFor(() => expect(screen.getByRole('button', { name: 'Mute' })).not.toBeDisabled());
    fireEvent.change(duration, { target: { value: '10800' } });
    fireEvent.click(screen.getByRole('button', { name: 'Mute' }));

    await waitFor(() => expect(mockPost).toHaveBeenCalledWith('/api/v1/hashtag_mutes', { name: '番組', expires_in: 10800 }));
  });

  it('uses a neutral heading when the replacement is empty and saves the original tag', async () => {
    const native = '👍';
    renderModal(native, {
      revision: '1',
      appliedRevision: '1',
      phase: 'ready',
      failure: null,
      rules: [{
        id: 'empty',
        revision: '1',
        emoji: { kind: 'unicode', native },
        replacement: '',
        effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
      }],
      availability: 'enabled',
      display: 'apply',
    });
    const dialog = await screen.findByRole('dialog', { name: `Mute #${'\u25FB'}?` });

    expect(document.getElementById('hashtag-mute-title').textContent).toBe(`Mute #${'\u25FB'}?`);
    expect(dialog.textContent).not.toContain(native);
    await waitFor(() => expect(screen.getByRole('button', { name: 'Mute' })).not.toBeDisabled());
    fireEvent.click(screen.getByRole('button', { name: 'Mute' }));
    await waitFor(() => expect(mockPost).toHaveBeenCalledWith('/api/v1/hashtag_mutes', { name: native }));
  });

  it('projects only the heading while the saved tag stays party👌', async () => {
    const native = '👌';
    const tag = `party${native}`;
    const store = renderModal(tag, {
      revision: '2',
      appliedRevision: '1',
      phase: 'stale',
      failure: null,
      rules: [],
      availability: 'enabled',
      display: 'suppress',
    });

    const dialog = await screen.findByRole('dialog', { name: `Mute #party${'\u25FB'}?` });
    const title = document.getElementById('hashtag-mute-title');

    expect(title.textContent).toBe(`Mute #party${'\u25FB'}?`);
    expect(dialog).toHaveAttribute('aria-labelledby', 'hashtag-mute-title');
    expect(dialog.textContent).not.toContain(native);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [{
          id: 'm-ok',
          revision: '3',
          emoji: { kind: 'unicode', native },
          replacement: '[ok]',
          effects: { replace_in_text: true, hide_reactions: false, hide_in_picker: false, reject_reactions_to_own_posts: false },
        }],
      });
    });

    expect(screen.getByRole('dialog', { name: 'Mute #party[ok]?' })).toBeTruthy();
    expect(screen.getByText('Mute #party[ok]?').textContent).not.toContain(native);

    await waitFor(() => expect(screen.getByRole('button', { name: 'Mute' })).not.toBeDisabled());
    fireEvent.click(screen.getByRole('button', { name: 'Mute' }));

    await waitFor(() => expect(mockPost).toHaveBeenCalledWith('/api/v1/hashtag_mutes', { name: tag }));
  });

  it('updates an existing mute in place and can remove it', async () => {
    mockGet.mockResolvedValue({
      data: [{
        id: '9',
        title: '#番組',
        context: ['home', 'thread'],
        filter_action: 'hide',
        expires_at: null,
        keywords: [],
        statuses: [],
        tags: [{ id: '1', name: '番組' }],
      }],
    });
    renderModal();

    await waitFor(() => expect(screen.getByRole('button', { name: 'Update mute' })).not.toBeDisabled());
    expect(screen.getByText('Home and lists')).toBeTruthy();
    expect(screen.getByText('Conversations')).toBeTruthy();
    expect(screen.queryByText('Notifications')).toBeNull();
    expect(screen.getByText('Currently muted with no end time.')).toBeTruthy();
    expect(screen.getByLabelText(/Duration/)).toHaveValue('');

    fireEvent.click(screen.getByRole('button', { name: 'Update mute' }));
    await waitFor(() => expect(mockPut).toHaveBeenCalledWith('/api/v1/hashtag_mutes/9', { preserve_expiry: true }));
    expect(mockPut).not.toHaveBeenCalledWith('/api/v1/hashtag_mutes/9', { expires_in: null });
  });

  it('keeps a chosen duration and tells a warn rule that updating hides posts', async () => {
    mockGet.mockResolvedValue({
      data: [{
        id: '9',
        title: '#番組',
        context: ['home'],
        filter_action: 'warn',
        expires_at: '2030-01-01T00:00:00Z',
        keywords: [],
        statuses: [],
        tags: [{ id: '1', name: '番組' }],
      }],
    });
    renderModal();

    await waitFor(() => expect(screen.getByLabelText(/Duration/)).toHaveValue(''));
    expect(screen.getByText('This rule is set to warn. Updating it hides matching posts again.')).toBeTruthy();

    fireEvent.change(screen.getByLabelText(/Duration/), { target: { value: '0' } });
    fireEvent.click(screen.getByRole('button', { name: 'Update mute' }));

    await waitFor(() => expect(mockPut).toHaveBeenCalledWith('/api/v1/hashtag_mutes/9', { expires_in: null }));
  });

  it('removes an existing mute without creating another filter', async () => {
    mockGet.mockResolvedValue({
      data: [{
        id: '9',
        title: '#番組',
        context: ['home'],
        filter_action: 'hide',
        expires_at: null,
        keywords: [],
        statuses: [],
        tags: [{ id: '1', name: '番組' }],
      }],
    });
    renderModal();

    await waitFor(() => expect(screen.getByRole('button', { name: 'Unmute' })).not.toBeDisabled());
    fireEvent.click(screen.getByRole('button', { name: 'Unmute' }));

    await waitFor(() => expect(mockDelete).toHaveBeenCalledWith('/api/v1/hashtag_mutes/9'));
    expect(mockPost).not.toHaveBeenCalled();
  });

  it('requires a new duration when the saved mute has already ended', async () => {
    mockGet.mockResolvedValue({
      data: [{
        id: '9',
        title: '#番組',
        context: ['home', 'thread'],
        filter_action: 'hide',
        expires_at: '2000-01-01T00:00:00Z',
        keywords: [],
        statuses: [],
        tags: [{ id: '1', name: '番組' }],
      }],
    });
    renderModal();

    const update = await screen.findByRole('button', { name: 'Update mute' });
    expect(update).toBeDisabled();
    expect(screen.queryByRole('option', { name: 'Don\'t change' })).toBeNull();
    expect(screen.getByText('The previous end time has passed. Choose a new duration before muting again.')).toBeTruthy();
    fireEvent.click(update);
    expect(mockPut).not.toHaveBeenCalled();

    fireEvent.change(screen.getByLabelText(/Duration/), { target: { value: '7200' } });
    expect(screen.getByRole('button', { name: 'Update mute' })).not.toBeDisabled();
    fireEvent.click(screen.getByRole('button', { name: 'Update mute' }));

    await waitFor(() => expect(mockPut).toHaveBeenCalledWith('/api/v1/hashtag_mutes/9', { expires_in: 7200 }));
  });

  it('does not mute when the settings request fails, then shows the saved mute after a retry', async () => {
    mockGet.mockRejectedValueOnce(new Error('offline'));
    renderModal();

    expect(await screen.findByRole('alert')).toHaveTextContent('could not be loaded');
    expect(screen.getByRole('button', { name: 'Mute' })).toBeDisabled();
    expect(screen.queryByText('Home and lists')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Mute' }));
    expect(mockPost).not.toHaveBeenCalled();
    expect(mockPut).not.toHaveBeenCalled();

    mockGet.mockResolvedValueOnce({
      data: [{
        id: '9',
        title: '#番組',
        context: ['home', 'thread'],
        filter_action: 'hide',
        expires_at: '2030-01-01T00:00:00Z',
        keywords: [],
        statuses: [],
        tags: [{ id: '1', name: '番組' }],
      }],
    });
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

    await waitFor(() => expect(screen.getByRole('button', { name: 'Update mute' })).not.toBeDisabled());
    expect(screen.getByText('Home and lists')).toBeTruthy();
    expect(screen.getByText('Conversations')).toBeTruthy();
    expect(screen.queryByText('Notifications')).toBeNull();
    expect(screen.getByLabelText(/Duration/)).toHaveValue('');
    fireEvent.click(screen.getByRole('button', { name: 'Update mute' }));
    await waitFor(() => expect(mockPut).toHaveBeenCalledWith('/api/v1/hashtag_mutes/9', { preserve_expiry: true }));
    expect(mockPost).not.toHaveBeenCalled();
  });

  it('can return to keeping the current end time after choosing another duration', async () => {
    mockGet.mockResolvedValue({
      data: [{
        id: '9',
        title: '#番組',
        context: ['home'],
        filter_action: 'hide',
        expires_at: '2030-01-01T00:00:00Z',
        keywords: [],
        statuses: [],
        tags: [{ id: '1', name: '番組' }],
      }],
    });
    renderModal();

    const duration = await screen.findByLabelText(/Duration/);
    await waitFor(() => expect(duration).toHaveValue(''));
    expect(screen.getByRole('option', { name: 'Don\'t change' })).toBeTruthy();

    fireEvent.change(duration, { target: { value: '7200' } });
    expect(duration).toHaveValue('7200');
    expect(screen.getByRole('option', { name: 'Don\'t change' })).toBeTruthy();

    fireEvent.change(duration, { target: { value: '' } });
    expect(duration).toHaveValue('');
    fireEvent.click(screen.getByRole('button', { name: 'Update mute' }));

    await waitFor(() => expect(mockPut).toHaveBeenCalledWith('/api/v1/hashtag_mutes/9', { preserve_expiry: true }));
    expect(mockPut).not.toHaveBeenCalledWith('/api/v1/hashtag_mutes/9', { expires_in: 7200 });
  });

  it('disables update when an open dialog reaches the end time', async () => {
    jest.useFakeTimers('modern');
    jest.setSystemTime(new Date('2026-11-15T00:00:00.000Z'));

    mockGet.mockResolvedValue({
      data: [{
        id: '9',
        title: '#番組',
        context: ['home', 'thread'],
        filter_action: 'hide',
        expires_at: '2026-11-15T00:00:05.000Z',
        keywords: [],
        statuses: [],
        tags: [{ id: '1', name: '番組' }],
      }],
    });
    renderModal();

    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    expect(screen.getByRole('button', { name: 'Update mute' })).not.toBeDisabled();
    expect(screen.getByRole('option', { name: 'Don\'t change' })).toBeTruthy();
    expect(screen.queryByText('The previous end time has passed. Choose a new duration before muting again.')).toBeNull();

    act(() => {
      jest.advanceTimersByTime(5000);
    });

    expect(screen.getByRole('button', { name: 'Update mute' })).toBeDisabled();
    expect(screen.queryByRole('option', { name: 'Don\'t change' })).toBeNull();
    expect(screen.getByText('The previous end time has passed. Choose a new duration before muting again.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Update mute' }));
    expect(mockPut).not.toHaveBeenCalled();

    jest.useRealTimers();
  });

  it('switches an enabled update to a new-duration prompt if the end time passes before the timer paints', async () => {
    jest.useFakeTimers('modern');
    jest.setSystemTime(new Date('2026-11-15T00:00:00.000Z'));

    mockGet.mockResolvedValue({
      data: [{
        id: '9',
        title: '#番組',
        context: ['home'],
        filter_action: 'hide',
        expires_at: '2026-11-15T00:00:05.000Z',
        keywords: [],
        statuses: [],
        tags: [{ id: '1', name: '番組' }],
      }],
    });
    renderModal();

    await act(async () => {
      await Promise.resolve();
      await Promise.resolve();
    });

    const update = screen.getByRole('button', { name: 'Update mute' });
    expect(update).not.toBeDisabled();

    act(() => {
      jest.setSystemTime(new Date('2026-11-15T00:00:05.000Z'));
    });
    expect(screen.getByRole('button', { name: 'Update mute' })).not.toBeDisabled();

    fireEvent.click(screen.getByRole('button', { name: 'Update mute' }));

    expect(mockPut).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Update mute' })).toBeDisabled();
    expect(screen.getByText('The previous end time has passed. Choose a new duration before muting again.')).toBeTruthy();

    jest.useRealTimers();
  });
});
