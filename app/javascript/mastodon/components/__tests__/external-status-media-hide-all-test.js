import { render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('react-intl', () => ({
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

jest.mock('mastodon/initial_state', () => ({
  displayMedia: 'hide_all',
}));

jest.mock('mastodon/components/media_gallery', () => () => null);
jest.mock('mastodon/features/video', () => () => null);
jest.mock('mastodon/features/audio', () => () => null);

import ExternalStatusMedia from '../external_status_media';

const textOnly = fromJS({
  id: '1',
  sensitive: true,
  media_attachments: [],
  fedibird_external: { canonical_url: 'https://example.com/story' },
});

const withRemote = fromJS({
  id: '1',
  sensitive: true,
  media_attachments: [],
  fedibird_external: {
    canonical_url: 'https://example.com/story',
    media: [{ id: 'clip', type: 'video', url: 'https://cdn.example/clip.mp4' }],
  },
});

describe('ExternalStatusMedia when every media item is hidden', () => {
  it('skips a text-only article and still hides a real remote file', () => {
    const empty = render(<ExternalStatusMedia sensitive status={textOnly} />);
    expect(empty.container.querySelector('button')).toBeNull();
    expect(empty.container.innerHTML).not.toContain('cdn.example');

    const remote = render(<ExternalStatusMedia sensitive status={withRemote} />);
    expect(remote.container.querySelector('button')).not.toBeNull();
    expect(remote.container.innerHTML).not.toContain('https://cdn.example/clip.mp4');
  });
});
