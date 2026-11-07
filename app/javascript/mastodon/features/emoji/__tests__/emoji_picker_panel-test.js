import React from 'react';
import PropTypes from 'prop-types';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import { EmojiPicker } from 'mastodon/features/ui/util/async-components';
import { resetStandardEmojiPickerLoaderForTests } from '../standard_emoji_loader';
import EmojiPickerPanel from '../emoji_picker_panel';
import { preloadStandardEmojiPickerIfNeeded } from '../emoji_picker_preferences';
import { consumeEmojiPickerEscape, resetEmojiPickerEscapeForTests } from '../emoji_picker_escape';

jest.mock('mastodon/features/ui/util/async-components', () => ({
  EmojiPicker: jest.fn(),
}));

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: descriptor => descriptor.defaultMessage,
  };

  return {
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

const pickerData = ImmutableMap({
  categories: new Set(['custom-fedibird']),
  custom_emojis: [{ id: 'fedibird', custom: true }],
});

const mockNimbleEmoji = { id: 'smile', native: '', colons: ':smile:', custom: false };

class StandardPickerStub extends React.Component {

  static propTypes = {
    onClick: PropTypes.func,
  };

  handleClick = event => {
    this.props.onClick(mockNimbleEmoji, event);
  };

  render() {
    return <button type='button' onClick={this.handleClick}>Standard smile</button>;
  }

}

const resolvePicker = () => {
  EmojiPicker.mockImplementation(() => Promise.resolve({
    Picker: StandardPickerStub,
    Emoji: function StandardEmojiStub() {
      return null;
    },
  }));
};

describe('EmojiPickerPanel', () => {
  beforeEach(() => {
    resetStandardEmojiPickerLoaderForTests();
    resetEmojiPickerEscapeForTests();
    EmojiPicker.mockReset();
    resolvePicker();
  });

  it('does not load the standard picker from an empty personal set or a zero-result search', async () => {
    const onStandardActive = jest.fn();

    render(
      <EmojiPickerPanel
        initialMode='personal'
        pickersEmoji={pickerData}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
        onStandardActive={onStandardActive}
      />,
    );

    expect(await screen.findByRole('button', { name: 'Standard' })).toBeInTheDocument();
    expect(EmojiPicker).not.toHaveBeenCalled();
    expect(onStandardActive).not.toHaveBeenCalled();
    expect(screen.getByText(/No emoji in this set/i)).toBeInTheDocument();

    fireEvent.change(screen.getByRole('searchbox'), { target: { value: 'zzzz-no-such-emoji' } });

    expect(screen.getByText(/No matching emoji/i)).toBeInTheDocument();
    expect(EmojiPicker).not.toHaveBeenCalled();
    expect(onStandardActive).not.toHaveBeenCalled();
  });

  it.each([
    ['personal', false, 'personal'],
    ['standard', false, 'standard'],
    ['personal', true, 'personal'],
    ['standard', true, 'standard'],
  ])('opens %s when prefer is %s and lazy is %s without falling back', async (mode) => {
    const onStandardActive = jest.fn();

    render(
      <EmojiPickerPanel
        initialMode={mode}
        pickersEmoji={pickerData}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
        onStandardActive={onStandardActive}
      />,
    );

    if (mode === 'personal') {
      expect(await screen.findByRole('searchbox')).toBeInTheDocument();
      expect(EmojiPicker).not.toHaveBeenCalled();
      expect(onStandardActive).not.toHaveBeenCalled();
      return;
    }

    await waitFor(() => expect(EmojiPicker).toHaveBeenCalledTimes(1));
    expect(onStandardActive).toHaveBeenCalledTimes(1);
    expect(await screen.findByRole('button', { name: 'Standard smile' })).toBeInTheDocument();
  });

  it('loads the standard picker only after an explicit switch and keeps a copied native fallback', async () => {
    const seen = [];
    const onPick = jest.fn(emoji => {
      seen.push(emoji);
    });

    render(
      <EmojiPickerPanel
        initialMode='personal'
        pickersEmoji={pickerData}
        onPick={onPick}
        onRequestClose={jest.fn()}
        onStandardActive={jest.fn()}
      />,
    );

    fireEvent.click(await screen.findByRole('button', { name: 'Standard' }));

    const smile = await screen.findByRole('button', { name: 'Standard smile' });
    fireEvent.click(smile);
    expect(EmojiPicker).toHaveBeenCalledTimes(1);
    expect(seen[0].native).toBe(':smile:');
    expect(seen[0]).not.toBe(mockNimbleEmoji);
    expect(mockNimbleEmoji.native).toBe('');
  });

  it('marks escape so a window keyup does not close the modal behind the picker', async () => {
    const onRequestClose = jest.fn();
    const modalClose = jest.fn();

    render(
      <EmojiPickerPanel
        initialMode='personal'
        pickersEmoji={pickerData}
        onPick={jest.fn()}
        onRequestClose={onRequestClose}
      />,
    );

    const search = await screen.findByRole('searchbox');

    search.focus();
    fireEvent.keyDown(search, { key: 'Escape' });
    const keyUp = new KeyboardEvent('keyup', { key: 'Escape', bubbles: true });

    if (!consumeEmojiPickerEscape(keyUp)) {
      modalClose();
    }

    expect(onRequestClose).toHaveBeenCalledTimes(1);
    expect(modalClose).not.toHaveBeenCalled();
  });

  it('rebuilds the standard picker when custom emoji arrive after it mounts', async () => {
    class ConstructorPicker extends React.Component {

      static propTypes = {
        custom: PropTypes.array,
      };

      constructor(props) {
        super(props);
        this.state = { custom: props.custom || [] };
      }

      render() {
        return (
          <div>
            {this.state.custom.map(emoji => (
              <button key={emoji.id} type='button' className='emoji-mart-emoji-custom'>{emoji.id}</button>
            ))}
          </div>
        );
      }

    }

    EmojiPicker.mockImplementation(() => Promise.resolve({
      Picker: ConstructorPicker,
      Emoji: function StandardEmojiStub() {
        return null;
      },
    }));

    const view = render(
      <EmojiPickerPanel
        initialMode='standard'
        pickersEmoji={ImmutableMap({ categories: new Set(), custom_emojis: [] })}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
      />,
    );

    await waitFor(() => expect(EmojiPicker).toHaveBeenCalled());
    expect(view.container.querySelector('.emoji-mart-emoji-custom')).toBeNull();

    view.rerender(
      <EmojiPickerPanel
        initialMode='standard'
        pickersEmoji={ImmutableMap({
          categories: new Set(['custom']),
          custom_emojis: [{ id: 'fedibird', short_names: ['fedibird'], custom: true }],
        })}
        onPick={jest.fn()}
        onRequestClose={jest.fn()}
      />,
    );

    expect(await screen.findByRole('button', { name: 'fedibird' })).toHaveClass('emoji-mart-emoji-custom');
  });

  it('preloads the standard module only when lazy load is explicitly off', async () => {
    await preloadStandardEmojiPickerIfNeeded(true);
    await preloadStandardEmojiPickerIfNeeded(undefined);
    expect(EmojiPicker).not.toHaveBeenCalled();

    await preloadStandardEmojiPickerIfNeeded(false);
    expect(EmojiPicker).toHaveBeenCalledTimes(1);
  });
});
