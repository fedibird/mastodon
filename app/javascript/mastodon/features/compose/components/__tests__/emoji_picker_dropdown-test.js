import React from 'react';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import { IntlProvider } from 'react-intl';

const mockEmojiPickerAsync = jest.fn(() => Promise.resolve({
  Picker: () => null,
  Emoji: () => null,
}));

jest.mock('mastodon/features/ui/util/async-components', () => ({
  EmojiPicker: mockEmojiPickerAsync,
}));

jest.mock('mastodon/initial_state', () => ({
  pickerEmojiSize: 22,
  disableAutoFocusToEmojiSearch: false,
}));

jest.mock('react-overlays/Overlay', () => () => null);

import EmojiPickerDropdown from '../emoji_picker_dropdown';

const Picker = () => {
  const [openDropdownId, setOpenDropdownId] = React.useState(null);

  return (
    <IntlProvider locale='en'>
      <EmojiPickerDropdown
        pickersEmoji={ImmutableMap()}
        openDropdownId={openDropdownId}
        onOpen={setOpenDropdownId}
        onClose={() => setOpenDropdownId(null)}
        onPickEmoji={jest.fn()}
        skinTone={1}
        onSkinTone={jest.fn()}
        frequentlyUsedEmojis={[]}
        button={<button type='button'>Insert emoji</button>}
      />
    </IntlProvider>
  );
};

describe('EmojiPickerDropdown with a native button trigger', () => {
  it('uses one focusable trigger and exposes expanded state on that button', async () => {
    const { container } = render(<Picker />);
    const trigger = screen.getByRole('button', { name: 'Insert emoji' });
    const wrapper = container.querySelector('.emoji-button');
    const focusable = container.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])');

    expect(focusable).toHaveLength(1);
    expect(wrapper).not.toHaveAttribute('role');
    expect(wrapper).not.toHaveAttribute('tabindex');
    expect(trigger).toHaveAttribute('aria-expanded', 'false');

    await act(async () => {
      fireEvent.click(trigger);
      await Promise.resolve();
    });

    expect(trigger).toHaveAttribute('aria-expanded', 'true');

    fireEvent.click(trigger);
    expect(trigger).toHaveAttribute('aria-expanded', 'false');
  });
});
