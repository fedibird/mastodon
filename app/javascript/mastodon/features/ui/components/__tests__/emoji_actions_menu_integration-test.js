/**
 * @jest-environment jsdom
 */
/* eslint-disable react/prop-types, react/jsx-no-bind */

import React from 'react';
import PropTypes from 'prop-types';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { fromJS } from 'immutable';
import { detailPathForReference } from 'mastodon/features/emoji/emoji_actions/reference';
import {
  appendPersonalCategoryItem,
  createEmojiMute,
  loadPersonalEmojiSetDocument,
  resolveEmojiReference,
} from 'mastodon/features/emoji/emoji_actions/api';
import { openEmojiActions, resetEmojiActionsBusForTests } from 'mastodon/features/emoji/emoji_actions/bus';
import { resetMuteMutationFlightsForTests } from 'mastodon/features/emoji/emoji_actions/mutation_flight';
import { resetPendingMuteSyncForTests } from 'mastodon/features/emoji/emoji_actions/pending_sync';
import { currentEmojiMutes } from 'mastodon/features/emoji/emoji_mute_store';
import { resetStandardEmojiPickerLoaderForTests } from 'mastodon/features/emoji/standard_emoji_loader';
import EmojiPickerPanel from 'mastodon/features/emoji/emoji_picker_panel';
import { EmojiPicker } from 'mastodon/features/ui/util/async-components';
import { copyText } from 'mastodon/utils/clipboard';
import { EmojiActionsMenuController } from '../emoji_actions_menu_controller';

jest.mock('react-overlays/Overlay', () => {
  return function MockOverlay({ show, children }) {
    if (!show) {
      return null;
    }

    return typeof children === 'function'
      ? children({ props: {}, arrowProps: {}, placement: 'bottom' })
      : children;
  };
});

jest.mock('mastodon/features/emoji/emoji_actions/api', () => ({
  createEmojiMute: jest.fn(() => Promise.resolve({ mute: { id: 'm1' }, revision: '2' })),
  deleteEmojiMute: jest.fn(),
  resolveEmojiReference: jest.fn(),
  loadPersonalEmojiSetDocument: jest.fn(() => Promise.resolve({
    revision: '1',
    categories: [{ id: 'cat-1', name: 'Favorites', items: [] }],
  })),
  appendPersonalCategoryItem: jest.fn(() => Promise.resolve({
    revision: '2',
    added: true,
    categories: [{ id: 'cat-1', name: 'Favorites', items: [{ key: 'k' }] }],
  })),
}));

jest.mock('mastodon/features/emoji/emoji_mute_store', () => ({
  currentEmojiMutes: jest.fn(() => []),
}));

jest.mock('mastodon/utils/clipboard', () => ({
  copyText: jest.fn(() => Promise.resolve()),
}));

jest.mock('mastodon/features/ui/util/async-components', () => ({
  EmojiPicker: jest.fn(),
}));

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: (descriptor, values = {}) => {
      let text = descriptor.defaultMessage || descriptor.id;
      Object.keys(values).forEach(key => {
        text = text.replace(`{${key}}`, values[key]);
      });
      return text;
    },
  };

  return {
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

const intl = {
  formatMessage: (descriptor, values = {}) => {
    let text = descriptor.defaultMessage || descriptor.id;
    Object.keys(values).forEach(key => {
      text = text.replace(`{${key}}`, values[key]);
    });
    return text;
  },
};

class StandardPickerStub extends React.Component {

  render() {
    return <button type='button'>Standard smile</button>;
  }

}

function mountPickerWithMenu(extraMenuProps = {}) {
  EmojiPicker.mockImplementation(() => Promise.resolve({
    Picker: StandardPickerStub,
    Emoji: () => null,
  }));

  const onRequestClose = jest.fn();

  render(
    <>
      <EmojiPickerPanel
        initialMode='standard'
        onPick={jest.fn()}
        onRequestClose={onRequestClose}
      />
      <EmojiActionsMenuController
        intl={intl}
        signedIn
        onSyncMutes={jest.fn(() => Promise.resolve())}
        {...extraMenuProps}
      />
    </>,
  );

  return { onRequestClose };
}

describe('emoji actions menu integration with picker outside-click', () => {
  beforeEach(() => {
    resetEmojiActionsBusForTests();
    resetMuteMutationFlightsForTests();
    resetPendingMuteSyncForTests();
    resetStandardEmojiPickerLoaderForTests();
    createEmojiMute.mockClear();
    appendPersonalCategoryItem.mockClear();
    copyText.mockClear();
    currentEmojiMutes.mockReturnValue([]);
    resolveEmojiReference.mockImplementation(reference => Promise.resolve({
      reference,
      actions: {
        mute: { allowed: true },
        add_to_personal_category: { allowed: true },
      },
    }));
    loadPersonalEmojiSetDocument.mockResolvedValue({
      revision: '1',
      categories: [{ id: 'cat-1', name: 'Favorites', items: [] }],
    });
  });

  afterEach(() => {
    resetEmojiActionsBusForTests();
  });

  it('keeps the picker open and runs mute when a menu item is clicked', async () => {
    const { onRequestClose } = mountPickerWithMenu();

    await screen.findByRole('button', { name: 'Standard smile' });

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    const muteItem = await screen.findByRole('button', { name: 'Mute emoji' });
    expect(muteItem.closest('[data-emoji-actions-menu="1"]')).not.toBeNull();

    fireEvent.click(muteItem);

    await waitFor(() => expect(createEmojiMute).toHaveBeenCalledTimes(1));
    expect(onRequestClose).not.toHaveBeenCalled();
  });

  it('copies unicode from the menu without closing via picker outside-click', async () => {
    const { onRequestClose } = mountPickerWithMenu();

    await screen.findByRole('button', { name: 'Standard smile' });

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    const copyItem = await screen.findByRole('button', { name: 'Copy emoji' });
    fireEvent.click(copyItem);

    await waitFor(() => expect(copyText).toHaveBeenCalledWith('😀'));
    expect(onRequestClose).not.toHaveBeenCalled();
  });

  it('adds to a personal category from the menu', async () => {
    const { onRequestClose } = mountPickerWithMenu();

    await screen.findByRole('button', { name: 'Standard smile' });

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'personal_picker' });
    });

    const addItem = await screen.findByRole('button', { name: 'Add to Favorites' });
    fireEvent.click(addItem);

    await waitFor(() => expect(appendPersonalCategoryItem).toHaveBeenCalledTimes(1));
    expect(onRequestClose).not.toHaveBeenCalled();
  });

  it('navigates to emoji detail from the menu', async () => {
    const history = { push: jest.fn() };

    class RouterHarness extends React.Component {

      static childContextTypes = { router: PropTypes.object };

      getChildContext() {
        return { router: { history } };
      }

      render() {
        return this.props.children;
      }

    }

    render(
      <RouterHarness>
        <EmojiActionsMenuController
          intl={intl}
          signedIn
          onSyncMutes={jest.fn(() => Promise.resolve())}
        />
      </RouterHarness>,
    );

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);
    const reference = { kind: 'unicode', native: '😀' };

    act(() => {
      openEmojiActions(reference, { anchor, source: 'emoji_detail' });
    });

    const detailItem = await screen.findByRole('button', { name: 'Emoji details' });
    fireEvent.click(detailItem);

    expect(history.push).toHaveBeenCalledWith(detailPathForReference(reference));
  });

  it('runs same-reaction from a reaction-source menu as the first item', async () => {
    const onAddEmojiReaction = jest.fn();
    const status = fromJS({ id: 'status-1', account: 'acct-1' });
    const getStatus = () => status;

    render(
      <EmojiActionsMenuController
        intl={intl}
        signedIn
        onSyncMutes={jest.fn(() => Promise.resolve())}
        onAddEmojiReaction={onAddEmojiReaction}
        onRemoveEmojiReaction={jest.fn()}
        getStatus={getStatus}
      />,
    );

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);

    act(() => {
      openEmojiActions(
        { kind: 'unicode', native: '😀' },
        {
          anchor,
          source: 'reaction',
          status_id: 'status-1',
          account_id: 'acct-1',
          reaction: {
            name: '😀',
            my_reaction: false,
            reaction_limit_reached: false,
            disabled: false,
          },
        },
      );
    });

    const reactItem = await screen.findByRole('button', { name: 'React with this emoji' });
    const muteItem = screen.getByRole('button', { name: 'Mute emoji' });
    expect(reactItem.compareDocumentPosition(muteItem) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();

    fireEvent.click(reactItem);

    expect(onAddEmojiReaction).toHaveBeenCalledTimes(1);
    expect(onAddEmojiReaction.mock.calls[0][0]).toBe(status);
    expect(onAddEmojiReaction.mock.calls[0][1]).toBe('😀');
  });
});
