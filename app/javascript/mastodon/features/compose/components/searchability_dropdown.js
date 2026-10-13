import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { injectIntl, defineMessages } from 'react-intl';
import IconButton from '../../../components/icon_button';
import Overlay from 'react-overlays/Overlay';
import { supportsPassiveEvents } from 'detect-passive-events';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';

const messages = defineMessages({
  public_short: { id: 'searchability.public.short', defaultMessage: 'Public' },
  public_long: { id: 'searchability.public.long', defaultMessage: 'Searchable for all' },
  private_short: { id: 'searchability.private.short', defaultMessage: 'Followers-only' },
  private_long: { id: 'searchability.private.long', defaultMessage: 'Searchable for followers only' },
  direct_short: { id: 'searchability.direct.short', defaultMessage: 'Reacted-users-only' },
  direct_long: { id: 'searchability.direct.long', defaultMessage: 'Searchable for reacted users only' },
  change_searchability: { id: 'searchability.change', defaultMessage: 'Adjust status searchability' },
  menu: { id: 'compose_form.overflow.searchability', defaultMessage: 'Search visibility' },
});

const listenerOptions = supportsPassiveEvents ? { passive: true } : false;

class SearchabilityDropdownMenu extends React.PureComponent {

  static propTypes = {
    style: PropTypes.object,
    className: PropTypes.string,
    popperRef: PropTypes.func,
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

    if (this.props.popperRef) {
      this.props.popperRef(c);
    }
  }

  setFocusRef = c => {
    this.focusedItem = c;
  }

  render () {
    const { style, className, items, value } = this.props;

    return (
      <div className={className} style={{ ...style }} role='listbox' data-testid='searchability-menu' ref={this.setRef}>
        {items.map(item => (
          <div role='option' tabIndex='0' key={item.value} data-index={item.value} onKeyDown={this.handleKeyDown} onClick={this.handleClick} className={classNames('privacy-dropdown__option', { active: item.value === value })} aria-selected={item.value === value} ref={item.value === value ? this.setFocusRef : null}>
            <div className='privacy-dropdown__option__icon'>
              <Icon id='search' fixedWidth />
              <Icon id={item.icon} fixedWidth />
            </div>

            <div className='privacy-dropdown__option__content'>
              <strong>{item.text}</strong>
              {item.meta}
            </div>
          </div>
        ))}
      </div>
    );
  }

}

export default @injectIntl
class SearchabilityDropdown extends React.PureComponent {

  static propTypes = {
    isUserTouching: PropTypes.func,
    onModalOpen: PropTypes.func,
    onModalClose: PropTypes.func,
    value: PropTypes.string.isRequired,
    prohibitedVisibilities: ImmutablePropTypes.set,
    onChange: PropTypes.func.isRequired,
    noDirect: PropTypes.bool,
    presentation: PropTypes.oneOf(['menu', 'detached']),
    open: PropTypes.bool,
    onClose: PropTypes.func,
    returnFocus: PropTypes.object,
    onMenuClose: PropTypes.func,
    container: PropTypes.func,
    intl: PropTypes.object.isRequired,
  };

  state = {
    open: false,
    placement: 'bottom',
  };

  handleToggle = () => {
    if (this.props.isUserTouching && this.props.isUserTouching()) {
      if (this.state.open) {
        this.props.onModalClose();
      } else {
        this.props.onModalOpen({
          actions: this.searchabilityOptions().map(option => ({ ...option, active: option.value === this.props.value })),
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

    const { value } = this.searchabilityOptions()[e.currentTarget.getAttribute('data-index')];

    this.props.onModalClose();
    this.finishMenuChoice(value);
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

  componentDidUpdate (prevProps) {
    if (this.props.presentation !== 'detached' || !this.props.open || prevProps.open) {
      return;
    }

    this.activeElement = this.props.returnFocus || document.activeElement;

    if (this.props.isUserTouching && this.props.isUserTouching()) {
      this.props.onModalOpen({
        actions: this.searchabilityOptions().map(option => ({ ...option, active: option.value === this.props.value })),
        onClick: this.handleModalActionClick,
      });

      if (this.props.onClose) {
        this.props.onClose();
      }
    }
  }

  handleClose = () => {
    const returnFocus = this.props.returnFocus || this.activeElement;

    if (returnFocus && typeof returnFocus.focus === 'function') {
      returnFocus.focus({ preventScroll: true });
    }

    if (this.props.presentation === 'detached') {
      if (this.props.onClose) {
        this.props.onClose();
      }

      return;
    }

    this.setState({ open: false });
  }

  handleChange = value => {
    this.props.onChange(value);
  }

  searchabilityOptions () {
    const { intl: { formatMessage }, prohibitedVisibilities } = this.props;

    return [
      { icon: 'globe', value: 'public', text: formatMessage(messages.public_short), meta: formatMessage(messages.public_long) },
      { icon: 'lock', value: 'private', text: formatMessage(messages.private_short), meta: formatMessage(messages.private_long) },
      { icon: 'at', value: 'direct', text: formatMessage(messages.direct_short), meta: formatMessage(messages.direct_long) },
    ].filter(option => !prohibitedVisibilities?.includes(option.value));
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

  handleOpenDedicated = (event) => {
    event.preventDefault();

    if (this.props.onMenuClose) {
      this.props.onMenuClose();
    }
  };

  finishMenuChoice = (value) => {
    this.props.onChange(value);
    this.handleClose();

    if (this.props.onMenuClose) {
      this.props.onMenuClose();
    }
  };

  render () {
    const { value, container, intl, presentation } = this.props;
    const { open, placement } = this.state;

    if (presentation === 'menu') {
      return (
        <button type='button' className='compose-form__menu-row' onClick={this.handleOpenDedicated}>
          <Icon id='search' fixedWidth aria-hidden='true' />
          <span>{intl.formatMessage(messages.menu)}</span>
        </button>
      );
    }

    if (presentation === 'detached') {
      const touching = this.props.isUserTouching && this.props.isUserTouching();

      return (
        <div className='compose-form__searchability-anchor' ref={this.setTargetRef}>
          <Overlay show={Boolean(this.props.open) && !touching} placement='bottom' flip target={this.findTarget} container={container} popperConfig={{ strategy: 'fixed', onFirstUpdate: this.handleOverlayEnter }}>
            {({ props, placement }) => (
              <SearchabilityDropdownMenu
                style={props.style}
                popperRef={props.ref}
                className={`compose-portal-menu compose-form__searchability-menu ${placement || ''}`}
                items={this.searchabilityOptions()}
                value={value}
                onClose={this.handleClose}
                onChange={this.handleChange}
              />
            )}
          </Overlay>
        </div>
      );
    }

    const options = this.searchabilityOptions();
    const valueOption = options.find(item => item.value === value);

    return (
      <div className={classNames('privacy-dropdown', placement, { active: open })} onKeyDown={this.handleKeyDown}>
        <div className={classNames('privacy-dropdown__value', { active: options.indexOf(valueOption) === (placement === 'bottom' ? 0 : (options.length - 1)) })} ref={this.setTargetRef}>
          <IconButton
            className='privacy-dropdown__value-icon'
            icon='search'
            // icon={valueOption.icon}
            title={intl.formatMessage(messages.change_searchability)}
            size={18}
            expanded={open}
            active={open}
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
                <SearchabilityDropdownMenu
                  items={options}
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
