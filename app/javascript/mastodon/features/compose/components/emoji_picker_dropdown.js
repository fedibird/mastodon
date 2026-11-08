import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import IconButton from '../../../components/icon_button';
import Overlay from 'react-overlays/Overlay';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { disableAutoFocusToEmojiSearch } from 'mastodon/initial_state';
import EmojiPickerPanel from 'mastodon/features/emoji/emoji_picker_panel';

const messages = defineMessages({
  emoji: { id: 'emoji_button.label', defaultMessage: 'Insert emoji' },
});

let id = 0;

class EmojiPickerDropdown extends React.PureComponent {

  static propTypes = {
    pickersEmoji: ImmutablePropTypes.map,
    frequentlyUsedEmojis: PropTypes.arrayOf(PropTypes.string),
    intl: PropTypes.object.isRequired,
    onOpen: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    openDropdownId: PropTypes.string,
    onPickEmoji: PropTypes.func.isRequired,
    onSkinTone: PropTypes.func.isRequired,
    skinTone: PropTypes.number.isRequired,
    button: PropTypes.node,
    onStandardActive: PropTypes.func,
    autoFocus: PropTypes.bool,
    initialMode: PropTypes.oneOf(['standard', 'personal']),
  };

  state = {
    placement: 'bottom',
    id: `custom_emoji:${id++}`,
  };

  componentDidMount() {
    this.mounted = true;
  }

  onShowDropdown = ({ target, type }) => {
    const { top } = target.getBoundingClientRect();
    this.setState({ placement: top * 2 < innerHeight ? 'bottom' : 'top' });
    this.props.onOpen(this.state.id, type !== 'click');
  };

  onHideDropdown = (event) => {
    if (event && typeof event.stopPropagation === 'function') {
      event.stopPropagation();
      event.preventDefault();
    }

    this.props.onClose(this.state.id);
  };

  finishClose = (event) => {
    if (this.skipTriggerFocus) {
      this.skipTriggerFocus = false;
    } else if (this.activeElement && typeof this.activeElement.focus === 'function') {
      this.activeElement.focus({ preventScroll: true });
      this.activeElement = null;
    }

    this.onHideDropdown(event);
  };

  handlePick = (emoji, event) => {
    if (!(event && (event.ctrlKey || event.metaKey))) {
      this.skipTriggerFocus = true;
    }

    this.props.onPickEmoji(emoji);
  };

  handleClick = (event) => {
    if (!event.key || event.key === 'Enter') {
      if (this.state.id === this.props.openDropdownId) {
        this.finishClose(event);
      } else {
        this.onShowDropdown(event);
      }
    }
  };

  handleMouseDown = () => {
    this.activeElement = document.activeElement;
  };

  handleCustomButtonClick = (event) => {
    const { button } = this.props;

    if (button.props.onClick) {
      button.props.onClick(event);
    }

    if (!event.defaultPrevented) {
      this.handleClick(event);
    }
  };

  handleCustomButtonMouseDown = (event) => {
    this.handleMouseDown();

    const { button } = this.props;

    if (button.props.onMouseDown) {
      button.props.onMouseDown(event);
    }
  };

  handleButtonKeyDown = (event) => {
    switch (event.key) {
    case ' ':
    case 'Enter':
      this.handleMouseDown();
      break;
    default:
    }
  };

  handleKeyPress = (event) => {
    switch (event.key) {
    case ' ':
    case 'Enter':
      this.handleClick(event);
      break;
    case 'Escape':
      this.finishClose(event);
      break;
    default:
    }
  };

  setTargetRef = node => {
    this.target = node;
  };

  findTarget = () => {
    return this.target;
  };

  componentWillUnmount = () => {
    this.mounted = false;

    if (this.state.id === this.props.openDropdownId) {
      this.onHideDropdown();
    }
  };

  render() {
    const { intl, onSkinTone, skinTone, frequentlyUsedEmojis, button, pickersEmoji, openDropdownId, onStandardActive, autoFocus, initialMode } = this.props;
    const title = intl.formatMessage(messages.emoji);
    const { placement } = this.state;
    const open = this.state.id === openDropdownId;
    const nativeButton = React.isValidElement(button) && button.type === 'button';

    return (
      <div className='emoji-picker-dropdown'>
        {nativeButton ? (
          <div className='emoji-button'>
            {React.cloneElement(button, {
              ref: this.setTargetRef,
              title: button.props.title || title,
              'aria-label': button.props['aria-label'] || title,
              'aria-expanded': open,
              onClick: this.handleCustomButtonClick,
              onMouseDown: this.handleCustomButtonMouseDown,
            })}
          </div>
        ) : (
          <div
            ref={this.setTargetRef}
            className='emoji-button'
            title={title}
            aria-label={title}
            aria-expanded={open}
            role='button'
            onClick={button ? this.handleClick : null}
            tabIndex={0}
          >
            {button || <IconButton
              className='privacy-dropdown__value-icon'
              icon='smile-o'
              title={intl.formatMessage(messages.emoji)}
              expanded={open}
              inverted
              style={{ height: null, lineHeight: '27px' }}
              onClick={this.handleClick}
              onMouseDown={this.handleMouseDown}
              onKeyDown={this.handleButtonKeyDown}
              onKeyPress={this.handleKeyPress}
            />}
          </div>
        )}

        <Overlay show={open} offset={[5, 15]} placement={placement} target={this.findTarget} popperConfig={{ strategy: 'fixed' }}>
          {({ props, arrowProps, placement: overlayPlacement }) => (
            <div {...props}>
              <div className={`dropdown-animation emoji-picker-dropdown__animation ${overlayPlacement}`}>
                <div className={`dropdown-menu__arrow ${overlayPlacement}`} {...arrowProps} />
                <EmojiPickerPanel
                  pickersEmoji={pickersEmoji}
                  onRequestClose={this.finishClose}
                  onPick={this.handlePick}
                  onSkinTone={onSkinTone}
                  skinTone={skinTone}
                  frequentlyUsedEmojis={frequentlyUsedEmojis}
                  onStandardActive={onStandardActive}
                  autoFocus={autoFocus === undefined ? !disableAutoFocusToEmojiSearch : autoFocus}
                  initialMode={initialMode}
                />
              </div>
            </div>
          )}
        </Overlay>
      </div>
    );
  }

}

export default injectIntl(EmojiPickerDropdown);
