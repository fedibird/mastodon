import React from 'react';
import PropTypes from 'prop-types';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import { resetStandardEmojiPickerLoaderForTests } from 'mastodon/features/emoji/standard_emoji_loader';

jest.mock('react-intl', () => {
  const intl = { formatMessage: descriptor => descriptor.defaultMessage };

  return {
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

jest.mock('react-overlays/Overlay', () => ({ children, show }) => (
  show ? children({ props: {}, arrowProps: {}, placement: 'bottom' }) : null
));

jest.mock('mastodon/features/ui/util/async-components', () => {
  const ReactInside = require('react');
  const PropTypesInside = require('prop-types');

  class StandardPicker extends ReactInside.Component {

    static propTypes = {
      onClick: PropTypesInside.func,
    };

    handleClick = event => {
      this.props.onClick({ id: 'smile', native: '😄' }, event);
    };

    render() {
      return ReactInside.createElement('button', { type: 'button', onClick: this.handleClick }, 'Smile');
    }

  }

  function StandardEmoji() {
    return null;
  }

  return {
    EmojiPicker: jest.fn(() => Promise.resolve({
      Picker: StandardPicker,
      Emoji: StandardEmoji,
    })),
  };
});

import ReactionPickerDropdown from '../reaction_picker_dropdown';

class Harness extends React.Component {

  static propTypes = {
    onPickEmoji: PropTypes.func.isRequired,
  };

  state = {
    openDropdownId: null,
  };

  handleOpen = openDropdownId => {
    this.setState({ openDropdownId });
  };

  handleClose = () => {
    this.setState({ openDropdownId: null });
  };

  handleSkinTone = () => {};

  render() {
    return (
      <ReactionPickerDropdown
        icon='smile-o'
        size={18}
        title='React with emoji'
        onOpen={this.handleOpen}
        onClose={this.handleClose}
        openDropdownId={this.state.openDropdownId}
        onPickEmoji={this.props.onPickEmoji}
        onSkinTone={this.handleSkinTone}
        skinTone={1}
        pickersEmoji={ImmutableMap({ categories: new Set(), custom_emojis: [] })}
      />
    );
  }

}

describe('ReactionPickerDropdown focus', () => {
  beforeEach(() => {
    resetStandardEmojiPickerLoaderForTests();
  });

  it('returns focus to the trigger after a normal selection', async () => {
    const onPickEmoji = jest.fn();

    render(<Harness onPickEmoji={onPickEmoji} />);
    const trigger = screen.getByRole('button', { name: 'React with emoji' });

    trigger.focus();
    fireEvent.click(trigger);
    fireEvent.click(await screen.findByRole('button', { name: 'Smile' }));

    await waitFor(() => expect(onPickEmoji).toHaveBeenCalledTimes(1));
    expect(document.activeElement).toBe(trigger);
  });
});
