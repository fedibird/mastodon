import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import IconButton from './icon_button';
import Overlay from 'react-overlays/Overlay';
import EmojiPickerPanel from 'mastodon/features/emoji/emoji_picker_panel';

let id = 0;

class ReactionPickerDropdown extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    icon: PropTypes.string.isRequired,
    size: PropTypes.number.isRequired,
    title: PropTypes.string.isRequired,
    active: PropTypes.bool,
    pressed: PropTypes.bool,
    iconButtonClass: PropTypes.string,
    disabled: PropTypes.bool,
    status: ImmutablePropTypes.map,
    isUserTouching: PropTypes.func,
    onOpen: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    openDropdownId: PropTypes.string,
    pickersEmoji: ImmutablePropTypes.map,
    onPickEmoji: PropTypes.func.isRequired,
    onSkinTone: PropTypes.func.isRequired,
    skinTone: PropTypes.number.isRequired,
    frequentlyUsedEmojis: PropTypes.arrayOf(PropTypes.string),
    counter: PropTypes.number,
    onStandardActive: PropTypes.func,
  };

  static defaultProps = {
    active: false,
    pressed: false,
    iconButtonClass: 'status__action-bar-button',
  };

  state = {
    id: `reaction:${id++}`,
  };

  handleClick = ({ type }) => {
    if (this.state.id === this.props.openDropdownId) {
      this.handleClose();
    } else {
      this.props.onOpen(this.state.id, type !== 'click');
    }
  };

  handleClose = () => {
    if (this.skipTriggerFocus) {
      this.skipTriggerFocus = false;
    } else if (this.activeElement && typeof this.activeElement.focus === 'function') {
      this.activeElement.focus({ preventScroll: true });
      this.activeElement = null;
    }

    this.props.onClose(this.state.id);
  };

  handlePick = (emoji) => {
    // A reaction has no separate text field. Closing returns to the trigger,
    // including after a normal selection. Ctrl/Meta does not close.
    this.props.onPickEmoji(emoji);
  };

  handleMouseDown = () => {
    this.activeElement = document.activeElement;
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
      event.stopPropagation();
      event.preventDefault();
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
    if (this.state.id === this.props.openDropdownId) {
      this.skipTriggerFocus = true;
      this.handleClose();
    }
  };

  render() {
    const { icon, size, title, disabled, openDropdownId, active, pressed, iconButtonClass, counter } = this.props;
    const { pickersEmoji, onSkinTone, skinTone, frequentlyUsedEmojis, onStandardActive } = this.props;
    const open = this.state.id === openDropdownId;

    return (
      <div className='emoji-picker-dropdown'>
        <span ref={this.setTargetRef}>
          <IconButton
            icon={icon}
            title={title}
            active={active}
            pressed={pressed}
            className={iconButtonClass}
            disabled={disabled}
            size={size}
            onClick={this.handleClick}
            onMouseDown={this.handleMouseDown}
            onKeyDown={this.handleButtonKeyDown}
            onKeyPress={this.handleKeyPress}
            counter={counter}
          />
        </span>

        <Overlay show={open} offset={[5, 5]} placement='bottom' flip target={this.findTarget} popperConfig={{ strategy: 'fixed' }}>
          {({ props, arrowProps, placement }) => (
            <div {...props}>
              <div className={`dropdown-animation emoji-picker-dropdown__animation ${placement}`}>
                <div className={`dropdown-menu__arrow ${placement}`} {...arrowProps} />
                <EmojiPickerPanel
                  notFoundVariant='reaction'
                  pickersEmoji={pickersEmoji}
                  onRequestClose={this.handleClose}
                  onPick={this.handlePick}
                  onSkinTone={onSkinTone}
                  skinTone={skinTone}
                  frequentlyUsedEmojis={frequentlyUsedEmojis}
                  onStandardActive={onStandardActive}
                />
              </div>
            </div>
          )}
        </Overlay>
      </div>
    );
  }

}

export default ReactionPickerDropdown;
