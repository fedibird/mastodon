/* eslint-disable react/prop-types */

import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import EmojiPickerShell from '../emoji_picker_shell';
import { EmojiActionsMenuController } from 'mastodon/features/ui/components/emoji_actions_menu_controller';
import { loadStandardEmojiPicker } from '../standard_emoji_loader';
import { loadPersonalEmojiStock } from '../emoji_stock_source';

jest.mock('mastodon/initial_state', () => ({
  emojiPickerDisableActions: true,
  emojiPickerDisablePersonal: false,
  emojiPickerDisableStandard: false,
  emojiPickerPreferPersonal: true,
  emojiPickerLazyLoadStandard: false,
}));

jest.mock('react-intl', () => {
  const intl = { formatMessage: descriptor => descriptor.defaultMessage };

  return {
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

const stock = {
  categories: [{
    id: 'favorites',
    name: 'Favorites',
    items: [{
      key: 'sample',
      label: 'Alpha',
      image: { src: '/emoji/alpha.svg', alt: '🅰️' },
      search: ['Alpha'],
      selection: { id: 'a', native: '🅰️', custom: false },
    }],
  }],
};

jest.mock('../emoji_stock_source', () => ({
  getCachedPersonalEmojiStock: jest.fn(() => null),
  getPickerEmojiSize: jest.fn(() => 22),
  loadPersonalEmojiStock: jest.fn(),
  subscribePersonalEmojiStock: jest.fn(() => () => {}),
  subscribePickerEmojiSize: jest.fn(() => () => {}),
}));

jest.mock('../standard_emoji_loader', () => ({
  loadStandardEmojiPicker: jest.fn(),
}));

class StandardPicker extends React.PureComponent {

  handlePick = event => {
    this.props.onClick({ id: 'smile', native: '😊', custom: false }, event);
  };

  render() {
    return (
      <div data-testid='standard-picker' data-actions-enabled={String(this.props.actionsEnabled)}>
        <button type='button' onClick={this.handlePick}>Standard smile</button>
      </div>
    );
  }

}

describe('picker action-menu preference is independent of both emoji sources', () => {
  beforeEach(() => {
    loadPersonalEmojiStock.mockReset();
    loadPersonalEmojiStock.mockResolvedValue({ status: 'ready', stock });
    loadStandardEmojiPicker.mockReset();
    loadStandardEmojiPicker.mockResolvedValue({ Picker: StandardPicker, Emoji: () => null });
  });

  it('ignores picker-scoped menu calls even when delegated DOM markers survive', () => {
    const controller = new EmojiActionsMenuController({ signedIn: true });
    const reference = { kind: 'unicode', native: '😊' };
    const root = document.createElement('div');
    const emoji = document.createElement('button');
    root.className = 'emoji-picker-shell';
    root.appendChild(emoji);

    controller.handleOpen({ reference, anchor: emoji, source: 'standard_picker' });
    controller.handleOpen({ reference, anchor: emoji, source: 'personal_picker' });
    controller.handleOpen({ reference, anchor: emoji, source: 'dataset' });
    expect(controller.state.element).toBeNull();

    emoji.dataset.emojiSource = 'standard_picker';
    const event = { preventDefault: jest.fn(), stopPropagation: jest.fn() };
    controller.openFromElement(emoji, event);
    expect(event.preventDefault).not.toHaveBeenCalled();
    expect(event.stopPropagation).not.toHaveBeenCalled();
  });

  it('retains standard mode, personal mode, and ordinary emoji insertion with menus disabled', async () => {
    const onPick = jest.fn();
    const onRequestClose = jest.fn();

    render(
      <EmojiPickerShell
        initialMode='standard'
        onPick={onPick}
        onRequestClose={onRequestClose}
      />,
    );

    expect(screen.getByRole('button', { name: 'Standard' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Personal set' })).toBeInTheDocument();
    // The native emoji-mart-bar:last-child CSS rule used to hide this mode
    // switch when the Edit bar was omitted for disabled action menus.
    const modeBar = screen.getByRole('group', { name: 'Emoji picker mode' });
    expect(modeBar).not.toHaveClass('emoji-mart-bar');
    expect(modeBar).toContainElement(screen.getByRole('button', { name: 'Personal set' }));
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();

    const standard = await screen.findByRole('button', { name: 'Standard smile' });
    expect(standard.parentElement).toHaveAttribute('data-actions-enabled', 'false');
    fireEvent.click(standard);
    expect(onPick).toHaveBeenCalledWith(expect.objectContaining({ native: '😊' }), expect.anything());

    fireEvent.click(screen.getByRole('button', { name: 'Personal set' }));
    const personal = await screen.findByRole('button', { name: 'Alpha' });
    expect(personal).not.toHaveAttribute('data-emoji-actions');
    fireEvent.click(personal);
    await waitFor(() => expect(onPick).toHaveBeenCalledTimes(2));
    expect(onPick.mock.calls[1][0]).toEqual(expect.objectContaining({ native: '🅰️' }));
    expect(loadPersonalEmojiStock).toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'Standard' }));
    expect(await screen.findByRole('button', { name: 'Standard smile' })).toBeInTheDocument();
    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(1);
  });
  it('keeps both source switch buttons when personal is preferred and menus are disabled', async () => {
    render(
      <EmojiPickerShell
        initialMode='personal'
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
      />,
    );

    const group = screen.getByRole('group', { name: 'Emoji picker mode' });
    expect(group).not.toHaveClass('emoji-mart-bar');
    expect(screen.getByRole('button', { name: 'Personal set' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: 'Standard' })).toHaveAttribute('aria-pressed', 'false');
    expect(await screen.findByRole('button', { name: 'Alpha' })).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: 'Standard' }));
    expect(await screen.findByRole('button', { name: 'Standard smile' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Standard' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: 'Personal set' })).toHaveAttribute('aria-pressed', 'false');
  });


});
