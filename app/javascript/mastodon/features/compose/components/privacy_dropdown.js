import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { injectIntl, defineMessages } from 'react-intl';
import IconButton from '../../../components/icon_button';
import Overlay from 'react-overlays/Overlay';
import { supportsPassiveEvents } from 'detect-passive-events';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import { hidePrivacyMeta } from '../../../initial_state';

const messages = defineMessages({
  public_short: { id: 'privacy.public.short', defaultMessage: 'Public' },
  public_long: { id: 'privacy.public.long', defaultMessage: 'Visible for all, shown in public timelines' },
  unlisted_short: { id: 'privacy.unlisted.short', defaultMessage: 'Unlisted' },
  unlisted_long: { id: 'privacy.unlisted.long', defaultMessage: 'Visible for all, but not in public timelines' },
  private_short: { id: 'privacy.private.short', defaultMessage: 'Followers-only' },
  private_long: { id: 'privacy.private.long', defaultMessage: 'Visible for followers only' },
  mutual_short: { id: 'privacy.mutual.short', defaultMessage: 'Mutuals-followers-only' },
  mutual_long: { id: 'privacy.mutual.long', defaultMessage: 'Visible for mutual followers only (Supported servers only)' },
  personal_short: { id: 'privacy.personal.short', defaultMessage: 'Personal' },
  personal_long: { id: 'privacy.personal.long', defaultMessage: 'Visible for personal only' },
  direct_short: { id: 'privacy.direct.short', defaultMessage: 'Direct' },
  direct_long: { id: 'privacy.direct.long', defaultMessage: 'Visible for mentioned users only' },
  limited_short: { id: 'privacy.limited.short', defaultMessage: 'Circle' },
  limited_long: { id: 'privacy.limited.long', defaultMessage: 'Visible for circle users only' },
  none_short: { id: 'privacy.none.short', defaultMessage: 'None' },
  none_long: { id: 'privacy.none.long', defaultMessage: 'No visibility allowed' },
  change_privacy: { id: 'privacy.change', defaultMessage: 'Adjust status privacy' },
});

const listenerOptions = supportsPassiveEvents ? { passive: true } : false;

class PrivacyDropdownMenu extends React.PureComponent {

  static propTypes = {
    style: PropTypes.object,
    items: PropTypes.array.isRequired,
    value: PropTypes.string.isRequired,
    onClose: PropTypes.func.isRequired,
    onChange: PropTypes.func.isRequired,
  };

  handleDocumentClick = e => {
    if (this.node && !this.node.contains(e.target)) {
      this.props.onClose();
    }
  }

  handleKeyDown = e => {
    const { items } = this.props;
    const value = e.currentTarget.getAttribute('data-index');
    const index = items.findIndex(item => {
      return (item.value === value);
    });
    let element = null;

    switch(e.key) {
    case 'Escape':
      this.props.onClose();
      break;
    case 'Enter':
      this.handleClick(e);
      break;
    case 'ArrowDown':
      element = this.node.childNodes[index + 1] || this.node.firstChild;
      break;
    case 'ArrowUp':
      element = this.node.childNodes[index - 1] || this.node.lastChild;
      break;
    case 'Tab':
      if (e.shiftKey) {
        element = this.node.childNodes[index - 1] || this.node.lastChild;
      } else {
        element = this.node.childNodes[index + 1] || this.node.firstChild;
      }
      break;
    case 'Home':
      element = this.node.firstChild;
      break;
    case 'End':
      element = this.node.lastChild;
      break;
    }

    if (element) {
      element.focus();
      this.props.onChange(element.getAttribute('data-index'));
      e.preventDefault();
      e.stopPropagation();
    }
  }

  handleClick = e => {
    const value = e.currentTarget.getAttribute('data-index');

    e.preventDefault();

    this.props.onClose();
    this.props.onChange(value);
  }

  componentDidMount () {
    document.addEventListener('click', this.handleDocumentClick, false);
    document.addEventListener('touchend', this.handleDocumentClick, listenerOptions);
    if (this.focusedItem) this.focusedItem.focus({ preventScroll: true });
  }

  componentWillUnmount () {
    document.removeEventListener('click', this.handleDocumentClick, false);
    document.removeEventListener('touchend', this.handleDocumentClick, listenerOptions);
  }

  setRef = c => {
    this.node = c;
  }

  setFocusRef = c => {
    this.focusedItem = c;
  }

  render () {
    const { style, items, value } = this.props;

    return (
      <div style={{ ...style }} role='listbox' ref={this.setRef}>
          {items.map(item => (
          <div role='option' tabIndex='0' key={item.value} data-index={item.value} onKeyDown={this.handleKeyDown} onClick={this.handleClick} className={classNames('privacy-dropdown__option', { active: item.value === value })} aria-selected={item.value === value} ref={item.value === value ? this.setFocusRef : null}>
            <div className='privacy-dropdown__option__icon'>
              <Icon id={item.icon} fixedWidth />
            </div>

            <div className='privacy-dropdown__option__content'>
              <strong>{item.text}</strong>
              {!hidePrivacyMeta && item.meta}
            </div>
          </div>
        ))}
      </div>
    );
  }

}

class PrivacyDropdown extends React.PureComponent {

  static propTypes = {
    isUserTouching: PropTypes.func,
    onModalOpen: PropTypes.func,
    onModalClose: PropTypes.func,
    value: PropTypes.string.isRequired,
    prohibitedVisibilities: ImmutablePropTypes.set,
    onChange: PropTypes.func.isRequired,
    noDirect: PropTypes.bool,
    disabled: PropTypes.bool,
    container: PropTypes.func,
    intl: PropTypes.object.isRequired,
  };

  state = {
    open: false,
    placement: 'bottom',
  };

  handleToggle = () => {
    if (this.props.disabled) {
      return;
    }

    if (this.props.isUserTouching && this.props.isUserTouching()) {
      if (this.state.open) {
        this.props.onModalClose();
      } else {
        this.props.onModalOpen({
          actions: this.options.map(option => ({ ...option, active: option.value === this.props.value })),
          onClick: this.handleModalActionClick,
        });
      }
    } else {
      if (this.state.open && this.activeElement) {
        this.activeElement.focus({ preventScroll: true });
      }
      this.setState({ open: !this.state.open });
    }
  }

  handleModalActionClick = (e) => {
    e.preventDefault();

    const { value } = this.options[e.currentTarget.getAttribute('data-index')];

    this.props.onModalClose();
    this.props.onChange(value);
  }

  handleKeyDown = e => {
    switch(e.key) {
    case 'Escape':
      this.handleClose();
      break;
    }
  }

  handleMouseDown = () => {
    if (!this.state.open) {
      this.activeElement = document.activeElement;
    }
  }

  handleButtonKeyDown = (e) => {
    switch(e.key) {
    case ' ':
    case 'Enter':
      this.handleMouseDown();
      break;
    }
  }

  handleClose = () => {
    if (this.state.open && this.activeElement) {
      this.activeElement.focus({ preventScroll: true });
    }
    this.setState({ open: false });
  }

  handleChange = value => {
    this.props.onChange(value);
  }

  componentWillMount () {
    const { intl: { formatMessage }, prohibitedVisibilities } = this.props;

    this.options = [
      { icon: 'globe', value: 'public', text: formatMessage(messages.public_short), meta: formatMessage(messages.public_long) },
      { icon: 'unlock', value: 'unlisted', text: formatMessage(messages.unlisted_short), meta: formatMessage(messages.unlisted_long) },
      { icon: 'lock', value: 'private', text: formatMessage(messages.private_short), meta: formatMessage(messages.private_long) },
      { icon: 'exchange', value: 'mutual', text: formatMessage(messages.mutual_short), meta: formatMessage(messages.mutual_long) },
      ...!this.props.noDirect && [
        { icon: 'user-circle', value: 'limited', text: formatMessage(messages.limited_short), meta: formatMessage(messages.limited_long) },
        { icon: 'envelope', value: 'direct', text: formatMessage(messages.direct_short), meta: formatMessage(messages.direct_long) },
        { icon: 'book', value: 'personal', text: formatMessage(messages.personal_short), meta: formatMessage(messages.personal_long) },
      ],
    ].filter(option => option && !prohibitedVisibilities?.includes(option.value));
  }

  setTargetRef = c => {
    this.target = c;
  }

  findTarget = () => {
    return this.target;
  }

  handleOverlayEnter = (state) => {
    this.setState({ placement: state.placement });
  }

  render () {
    const { value, container, intl } = this.props;
    const { open, placement } = this.state;

    const valueOption = this.options.find(item => item.value === value) || { icon: 'ban', value: 'none', text: intl.formatMessage(messages.none_short), meta: intl.formatMessage(messages.none_long) };

    return (
      <div className={classNames('privacy-dropdown', placement, { active: open })} onKeyDown={this.handleKeyDown}>
        <div className={classNames('privacy-dropdown__value', { active: this.options.indexOf(valueOption) === (placement === 'bottom' ? 0 : (this.options.length - 1)) })} ref={this.setTargetRef}>
          <IconButton
            className='privacy-dropdown__value-icon'
            icon={valueOption.icon}
            title={intl.formatMessage(messages.change_privacy)}
            size={18}
            expanded={open}
            active={open}
            disabled={this.props.disabled}
            inverted
            onClick={this.handleToggle}
            onMouseDown={this.handleMouseDown}
            onKeyDown={this.handleButtonKeyDown}
            style={{ height: null, lineHeight: '27px' }}
          />
        </div>

        <Overlay show={open} placement={'bottom'} flip target={this.findTarget} container={container} popperConfig={{ strategy: 'fixed', onFirstUpdate: this.handleOverlayEnter }}>
          {({ props, placement }) => (
            <div {...props} style={{ ...props.style, width: 350, maxWidth: '100vw' }}>
              <div className={`dropdown-animation privacy-dropdown__dropdown ${placement}`}>
                <PrivacyDropdownMenu
                  items={this.options}
                  value={value}
                  onClose={this.handleClose}
                  onChange={this.handleChange}
                />
              </div>
            </div>
          )}
        </Overlay>
      </div>
    );
  }

}

export default injectIntl(PrivacyDropdown);
