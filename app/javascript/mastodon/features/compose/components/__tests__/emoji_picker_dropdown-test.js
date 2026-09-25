/* eslint-disable react/prop-types */

import React from 'react';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';

const emojiMart = {
  props: [],
  resolve: null,
};

jest.mock('react-intl', () => {
  const intl = { formatMessage: () => 'Insert emoji' };

  return {
    defineMessages: messages => messages,
    FormattedMessage: () => null,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

jest.mock('mastodon/features/ui/util/async-components', () => ({
  EmojiPicker: jest.fn(() => new Promise(resolve => {
    emojiMart.resolve = resolve;
  })),
}));

jest.mock('mastodon/initial_state', () => ({
  pickerEmojiSize: 22,
  disableAutoFocusToEmojiSearch: false,
}));

jest.mock('react-overlays/Overlay', () => ({ children, show }) => (
  show ? children({ props: {}, arrowProps: {}, placement: 'bottom' }) : null
));

import EmojiPickerDropdown from '../emoji_picker_dropdown';

const noop = () => {};
const pickerData = ImmutableMap({ categories: new Set(), custom_emojis: [] });

const Picker = ({ frequentlyUsedEmojis = [], onClose = noop }) => {
  const [openDropdownId, setOpenDropdownId] = React.useState(null);
  const handleClose = React.useCallback(() => {
    onClose();
    setOpenDropdownId(null);
  }, [onClose]);

  return (
    <EmojiPickerDropdown
      pickersEmoji={pickerData}
      openDropdownId={openDropdownId}
      onOpen={setOpenDropdownId}
      onClose={handleClose}
      onPickEmoji={noop}
      skinTone={1}
      onSkinTone={noop}
      frequentlyUsedEmojis={frequentlyUsedEmojis}
      button={<button type='button'>Insert emoji</button>}
    />
  );
};

const resolveEmojiMart = () => emojiMart.resolve({
  Picker: props => {
    emojiMart.props.push(props);

    return <div>Emoji picker</div>;
  },
  Emoji: () => null,
});

describe('EmojiPickerDropdown with a native button trigger', () => {
  beforeEach(() => {
    emojiMart.props = [];
  });

  it('does not update state after unmounting during picker loading', async () => {
    const error = jest.spyOn(console, 'error').mockImplementation(() => {});
    const { unmount } = render(<Picker />);

    fireEvent.click(screen.getByRole('button', { name: 'Insert emoji' }));
    unmount();
    await act(async () => {
      resolveEmojiMart();
    });

    expect(error).not.toHaveBeenCalled();
    error.mockRestore();
  });

  it('uses one focusable trigger and exposes expanded state on that button', async () => {
    const { container } = render(<Picker />);
    const trigger = screen.getByRole('button', { name: 'Insert emoji' });
    const wrapper = container.querySelector('.emoji-button');
    const focusable = container.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])');

    expect(focusable).toHaveLength(1);
    expect(wrapper).not.toHaveAttribute('role');
    expect(wrapper).not.toHaveAttribute('tabindex');
    expect(trigger).toHaveAttribute('aria-expanded', 'false');

    fireEvent.click(trigger);
    await waitFor(() => expect(screen.getByRole('button', { name: 'Insert emoji' })).toHaveAttribute('aria-expanded', 'true'));

    fireEvent.click(screen.getByRole('button', { name: 'Insert emoji' }));
    expect(screen.getByRole('button', { name: 'Insert emoji' })).toHaveAttribute('aria-expanded', 'false');
  });

  it('opens an empty frequent list without passing recent to emoji mart', async () => {
    render(<Picker frequentlyUsedEmojis={[]} />);

    fireEvent.click(screen.getByRole('button', { name: 'Insert emoji' }));
    await act(async () => {
      resolveEmojiMart();
    });

    expect(screen.getByText('Emoji picker')).toBeInTheDocument();
    expect(emojiMart.props[0].recent).toBeUndefined();
  });

  it('passes a populated frequent list through to emoji mart', async () => {
    render(<Picker frequentlyUsedEmojis={['grinning']} />);

    fireEvent.click(screen.getByRole('button', { name: 'Insert emoji' }));
    await act(async () => {
      resolveEmojiMart();
    });

    expect(emojiMart.props[0].recent).toEqual(['grinning']);
  });

  it('closes an open picker during unmount without an event', () => {
    const onClose = jest.fn();
    const { unmount } = render(<Picker onClose={onClose} />);

    fireEvent.click(screen.getByRole('button', { name: 'Insert emoji' }));
    expect(() => unmount()).not.toThrow();
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
