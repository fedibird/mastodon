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

import MediaContainer from '../media_container';

const overlay = () => document.querySelector('.modal-root__overlay');

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
  it('keeps the modal overlay closed until a media or history revision is open', () => {
    mount();
    expect(overlay()).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Open media' }));
    expect(overlay()).not.toBeNull();
    expect(screen.getByText('Media modal')).toBeInTheDocument();

    fireEvent.click(overlay());
    expect(overlay()).toBeNull();
    expect(screen.queryByText('Media modal')).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Open history' }));
    expect(overlay()).not.toBeNull();
    expect(screen.getByText('History revision <p>edited</p>')).toBeInTheDocument();

    fireEvent.click(overlay());
    expect(overlay()).toBeNull();
    expect(screen.queryByText(/History revision/)).not.toBeInTheDocument();
  });
});
