/* eslint-disable react/prop-types */

import React from 'react';
import { render, screen } from '@testing-library/react';
import EmojiPickerShell from '../emoji_picker_shell';
import EmojiPickerPanel from '../emoji_picker_panel';
import { getCachedPersonalEmojiStock, loadPersonalEmojiStock, subscribePersonalEmojiStock, subscribePickerEmojiSize } from '../emoji_stock_source';
import { loadStandardEmojiPicker } from '../standard_emoji_loader';

jest.mock('mastodon/initial_state', () => ({
  autoPlayEmoji: false,
  disableAutoFocusToEmojiSearch: false,
  emojiPickerDisablePersonal: true,
  emojiPickerDisableActions: true,
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

const StandardPicker = ({ onClick, actionsEnabled }) => {
  const handleClick = event => onClick({ id: 'smile', native: '😊' }, event);

  return (
    <button data-actions-enabled={String(actionsEnabled)} type='button' onClick={handleClick}>Standard smile</button>
  );
};

describe('personal emoji picker disabled', () => {
  beforeEach(() => {
    getCachedPersonalEmojiStock.mockClear();
    loadPersonalEmojiStock.mockReset();
    subscribePersonalEmojiStock.mockClear();
    subscribePickerEmojiSize.mockClear();
    loadStandardEmojiPicker.mockReset();
    loadStandardEmojiPicker.mockResolvedValue({ Picker: StandardPicker, Emoji: () => null });
  });

  it('uses standard mode even if a caller requests and enables personal mode', async () => {
    render(<EmojiPickerShell personalEnabled initialMode='personal' actionsEnabled onPick={jest.fn()} />);

    expect(await screen.findByRole('button', { name: 'Standard smile' })).toHaveAttribute('data-actions-enabled', 'false');
    expect(screen.queryByRole('button', { name: 'Personal set' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Edit' })).not.toBeInTheDocument();
    expect(getCachedPersonalEmojiStock).not.toHaveBeenCalled();
    expect(loadPersonalEmojiStock).not.toHaveBeenCalled();
    expect(subscribePersonalEmojiStock).not.toHaveBeenCalled();
  });

  it('opens panel as standard-only without personal stock or size subscriptions', async () => {
    render(<EmojiPickerPanel initialMode='personal' onPick={jest.fn()} onRequestClose={jest.fn()} />);

    expect(await screen.findByRole('button', { name: 'Standard smile' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Personal set' })).not.toBeInTheDocument();
    expect(getCachedPersonalEmojiStock).not.toHaveBeenCalled();
    expect(loadPersonalEmojiStock).not.toHaveBeenCalled();
    expect(subscribePersonalEmojiStock).not.toHaveBeenCalled();
    expect(subscribePickerEmojiSize).not.toHaveBeenCalled();
  });
});
