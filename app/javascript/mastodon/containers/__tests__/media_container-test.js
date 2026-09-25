/* eslint-disable react/prop-types, react/jsx-no-bind */

import { render, screen, fireEvent } from '@testing-library/react';
import React from 'react';

jest.mock('mastodon/locales', () => ({
  getLocale: () => ({ localeData: [], messages: {} }),
}));

jest.mock('react-intl', () => {
  const React = require('react');

  return {
    addLocaleData: () => {},
    IntlProvider: ({ children }) => <div>{children}</div>,
  };
});

jest.mock('mastodon/components/media_gallery', () => {
  const React = require('react');

  return ({ onOpenMedia }) => (
    <button type='button' onClick={() => onOpenMedia(require('immutable').fromJS([{ id: 'm1' }]), 0)}>Open media</button>
  );
});
jest.mock('mastodon/features/video', () => {
  const React = require('react');

  return ({ onOpenVideo, componetIndex }) => (
    <button type='button' onClick={() => onOpenVideo({ startTime: 1, componetIndex })}>Open video</button>
  );
});
jest.mock('mastodon/features/status/components/card', () => () => null);
jest.mock('mastodon/components/poll', () => () => null);
jest.mock('mastodon/components/hashtag', () => () => null);
jest.mock('mastodon/features/audio', () => () => null);
jest.mock('mastodon/features/ui/components/media_modal', () => () => <div>Media modal</div>);
jest.mock('mastodon/components/status_history_revision', () => ({ revision }) => <div>History revision {revision.get('content')}</div>);
jest.mock('mastodon/components/public_status_history', () => {
  const React = require('react');

  return ({ onOpenRevision }) => (
    <button type='button' onClick={() => onOpenRevision(require('immutable').fromJS({ content: '<p>edited</p>', account: null }), 'en')}>Open history</button>
  );
});
jest.mock('mastodon/components/modal_root', () => ({ children }) => <div>{children}</div>);

import MediaContainer from '../media_container';

const mount = () => {
  const mediaNode = document.createElement('div');
  mediaNode.setAttribute('data-component', 'MediaGallery');
  mediaNode.setAttribute('data-props', JSON.stringify({ media: [] }));

  const videoNode = document.createElement('div');
  videoNode.setAttribute('data-component', 'Video');
  videoNode.setAttribute('data-props', JSON.stringify({ media: [{ id: 'v1' }] }));

  const historyNode = document.createElement('div');
  historyNode.setAttribute('data-component', 'StatusHistory');
  historyNode.setAttribute('data-props', JSON.stringify({ statusId: 's1', editedAt: '2026-01-01T00:00:00.000Z', historyUrl: '/history' }));

  document.body.append(mediaNode, videoNode, historyNode);

  return render(<MediaContainer locale='en' components={[mediaNode, videoNode, historyNode]} />);
};

describe('MediaContainer', () => {
  it('opens the media modal and the history revision without replacing each other permanently', () => {
    mount();

    fireEvent.click(screen.getByRole('button', { name: 'Open media' }));
    expect(screen.getByText('Media modal')).toBeInTheDocument();
    expect(document.body.classList.contains('with-modals--active')).toBe(true);

    fireEvent.click(screen.getByRole('button', { name: 'Open history' }));
    expect(screen.queryByText('Media modal')).not.toBeInTheDocument();
    expect(screen.getByText('History revision <p>edited</p>')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Open video' }));
    expect(screen.queryByText('History revision <p>edited</p>')).not.toBeInTheDocument();
    expect(screen.getByText('Media modal')).toBeInTheDocument();
  });
});
