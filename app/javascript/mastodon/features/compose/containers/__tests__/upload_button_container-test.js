import { render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => props => <Component {...props} intl={{ formatMessage: message => message.defaultMessage }} />,
}));

jest.mock('mastodon/initial_state', () => ({
  allowPollImage: true,
  maxAttachments: 4,
}));

import { attachmentUploadBlocked } from '../../composer_media';
import UploadButtonContainer from '../upload_button_container';
import { ComposerProvider } from '../../composer_id_context';

const accept = ImmutableList(['image/png', 'image/jpeg', 'video/mp4', 'audio/mpeg']);

const composer = (media = []) => ImmutableMap({
  media_attachments: ImmutableList(media.map(type => ImmutableMap({ type }))),
  is_uploading: false,
  pending_media_attachments: 0,
  pending_exclusive_attachments: 0,
  poll: null,
  resetFileKey: 1,
});

const renderButton = (state, composerId = 'primary') => {
  const store = createStore(() => state);
  const onSelect = jest.fn();

  render(
    <Provider store={store}>
      <ComposerProvider composerId={composerId}>
        <UploadButtonContainer />
      </ComposerProvider>
    </Provider>,
  );

  return { onSelect };
};

describe('UploadButton accept types', () => {
  const base = extra => ImmutableMap({
    compose: composer(),
    composers: ImmutableMap({ byId: ImmutableMap() }),
    media_attachments: ImmutableMap({ accept_content_types: accept }),
    ...extra,
  });

  it('keeps the server accept list when nothing is attached', () => {
    renderButton(base());

    expect(document.querySelector('input[type="file"]').getAttribute('accept')).toBe('image/png,image/jpeg,video/mp4,audio/mpeg');
    expect(screen.getByRole('button', { name: 'Add images, a video or an audio file' })).toBeEnabled();
  });

  it('offers only images after an image is attached and blocks video or audio', () => {
    renderButton(base({ compose: composer(['image']) }));

    expect(document.querySelector('input[type="file"]').getAttribute('accept')).toBe('image/png,image/jpeg');
    expect(attachmentUploadBlocked({
      existingTypes: ['image'],
      incomingMimeTypes: ['video/mp4'],
    })).toBe(true);
    expect(attachmentUploadBlocked({
      existingTypes: ['image'],
      incomingMimeTypes: ['image/png'],
    })).toBe(false);
  });

  it('disables another attachment when a video is already attached', () => {
    const portable = composer(['video']);
    renderButton(base({
      composers: ImmutableMap({
        byId: ImmutableMap({ 'portable:list:1': portable }),
      }),
    }), 'portable:list:1');

    expect(screen.getByRole('button', { name: 'Add images, a video or an audio file' })).toBeDisabled();
    expect(attachmentUploadBlocked({
      existingTypes: ['video'],
      incomingMimeTypes: ['image/png'],
    })).toBe(true);
  });

});
