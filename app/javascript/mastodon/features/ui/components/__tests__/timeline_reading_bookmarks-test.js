import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: (message, values) => {
      let text = message.defaultMessage || message.id;

      if (values) {
        Object.keys(values).forEach(key => {
          text = text.replace(`{${key}}`, values[key]);
        });
      }

      return text;
    },
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import TimelineReadingBookmarksPanel from '../timeline_reading_bookmarks';

const home = {
  source: 'home',
  path: '/api/v1/timelines/home',
  params: {},
};

const anchor = {
  version: 1,
  statusId: '80',
  displayRowId: '80',
  offsetPx: 6,
  alignment: 'top',
};

const row = (overrides = {}) => ({
  id: '4',
  name: 'Morning',
  source: 'home',
  sourceTimelineId: 'home',
  context: {},
  anchor,
  sourceLabel: null,
  availability: { source: 'available', anchor: 'visible', membership: 'unchecked', limitations: ['retention_2000'] },
  lockVersion: 0,
  updatedAt: '2026-10-18T01:00:00Z',
  ...overrides,
});

const renderPanel = (props) => {
  const onList = props.onList || jest.fn(() => Promise.resolve([]));

  return render(
    <TimelineReadingBookmarksPanel
      contract={home}
      panelId='bookmarks-1'
      onClose={jest.fn()}
      onCapture={jest.fn(() => ({ ok: true, anchor }))}
      onList={onList}
      onCreate={jest.fn(() => Promise.resolve(row()))}
      onRename={jest.fn(() => Promise.resolve(row({ name: 'Later', lockVersion: 1 })))}
      onDelete={jest.fn(() => Promise.resolve({}))}
      onRestore={jest.fn(() => Promise.resolve({ place: 'exact', reason: 'loaded' }))}
      {...props}
    />,
  );
};

describe('TimelineReadingBookmarksPanel', () => {
  it('saves only after the request succeeds and keeps a failure unsaved', async () => {
    const onCreate = jest.fn(() => Promise.resolve(row({ name: 'Later' })));
    const onCapture = jest.fn(() => ({ ok: true, anchor }));

    renderPanel({ onCreate, onCapture });
    fireEvent.change(screen.getByLabelText('Bookmark name'), { target: { value: '  Later  ' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save this position' }));

    expect(onCapture).toHaveBeenCalledTimes(1);
    expect(onCreate).toHaveBeenCalledWith({ name: '  Later  ', anchor });
    expect(screen.queryByText('Saved “Later”.')).toBeNull();

    await screen.findByText('Saved “Later”.');
    cleanup();

    const failed = jest.fn(() => Promise.reject({ reason: 'duplicate_name' }));

    renderPanel({ onCreate: failed, onCapture });
    fireEvent.change(screen.getByLabelText('Bookmark name'), { target: { value: 'Later' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save this position' }));
    expect(await screen.findByText('You already have a bookmark with that name.')).toBeTruthy();
    expect(screen.queryByText('Saved “Later”.')).toBeNull();
  });

  it('does not submit while an IME composition is ending and Escape closes the dialog', () => {
    const onCreate = jest.fn();
    const onClose = jest.fn();

    renderPanel({ onCreate, onClose });
    const name = screen.getByLabelText('Bookmark name');

    fireEvent.compositionStart(name);
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Enter', keyCode: 229 });
    fireEvent.submit(name.closest('form'));
    expect(onCreate).not.toHaveBeenCalled();

    fireEvent.compositionEnd(name);
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Enter' });
    expect(onCreate).not.toHaveBeenCalled();

    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('reloads on a rename conflict and asks before deleting', async () => {
    const saved = row();
    const onList = jest.fn(() => Promise.resolve([saved]));
    const onRename = jest.fn(() => Promise.reject({ reason: 'conflict' }));
    const onDelete = jest.fn(() => Promise.resolve({}));

    renderPanel({ onList, onRename, onDelete });
    fireEvent.click(await screen.findByRole('button', { name: 'Rename' }));
    fireEvent.change(screen.getByLabelText('Rename'), { target: { value: 'Later' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save name' }));

    expect(await screen.findByText('That bookmark changed somewhere else. The list was reloaded.')).toBeTruthy();
    expect(onList).toHaveBeenCalledTimes(2);
    expect(screen.queryByText('Renamed to “Later”.')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }));
    expect(onDelete).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Delete bookmark' }));
    expect(onDelete).toHaveBeenCalledWith(saved);
    expect(await screen.findByText('Deleted “Morning”.')).toBeTruthy();
  });

  it('does not show a missing timeline name and explains a different source without calling it saved', async () => {
    const onList = jest.fn(() => Promise.resolve([
      row({
        id: '9',
        name: 'Secret place',
        source: 'list',
        sourceTimelineId: 'list:9',
        context: { id: '9' },
        sourceLabel: 'Secret list',
        availability: { source: 'missing', anchor: 'not_found', membership: 'unchecked' },
      }),
    ]));
    const onRestore = jest.fn(() => Promise.resolve({ place: 'different_source', reason: 'different_source' }));

    renderPanel({ onList, onRestore });
    fireEvent.click(screen.getByRole('button', { name: 'All timelines' }));

    expect(await screen.findByText('Secret place')).toBeTruthy();
    expect(screen.queryByText('Secret list')).toBeNull();
    expect(screen.getByText('That timeline is gone or no longer open to you. Its name is hidden.')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Return' }));
    expect(await screen.findByText('This bookmark belongs to another timeline. Open that timeline to return to it. This column was not moved.')).toBeTruthy();
    expect(onRestore).toHaveBeenCalledTimes(1);
    expect(screen.getByRole('status')).toBeTruthy();
  });

  it('refuses the 51st save before the request', async () => {
    const bookmarks = Array.from({ length: 50 }, (_, index) => row({ id: String(index + 1), name: `Place ${index}` }));
    const onCreate = jest.fn();

    renderPanel({ onList: () => Promise.resolve(bookmarks), onCreate });
    expect(await screen.findAllByRole('button', { name: 'Return' })).toHaveLength(50);
    fireEvent.change(screen.getByLabelText('Bookmark name'), { target: { value: 'One more' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save this position' }));

    expect(onCreate).not.toHaveBeenCalled();
    expect(screen.getAllByText('50 bookmarks is the limit. Delete one before saving another.').length).toBeGreaterThan(0);
  });
});
