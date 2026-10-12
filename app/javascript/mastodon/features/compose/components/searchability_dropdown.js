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
    presentation: PropTypes.oneOf(['menu']),
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

  renderMenuOptions () {
    return this.options.map(item => (
      <button
        key={item.value}
        type='button'
        className='compose-form__menu-row'
        data-index={item.value}
        onClick={this.handleMenuChoice}
      >
        <Icon id={item.icon} fixedWidth aria-hidden='true' />
        <span>{item.text}</span>
      </button>
    ));
  }

  finishMenuChoice = (value) => {
    this.props.onChange(value);
    this.handleClose();

    if (this.props.onMenuClose) {
      this.props.onMenuClose();
    }
  };

  handleMenuChoice = event => {
    event.preventDefault();
    this.finishMenuChoice(event.currentTarget.getAttribute('data-index'));
  };

  render () {
    const { value, container, intl, presentation } = this.props;
    const { open, placement } = this.state;

    if (presentation === 'menu') {
      const touching = this.props.isUserTouching && this.props.isUserTouching();

      return (
        <div className='compose-form__searchability-menu'>
          <button type='button' className='compose-form__menu-row' aria-expanded={open} onClick={this.handleToggle}>
            <span aria-hidden='true'>🔎</span>
            <span>{intl.formatMessage(messages.menu)}</span>
          </button>
          {open && !touching ? (
            <div role='listbox'>
              {this.renderMenuOptions()}
            </div>
          ) : null}
        </div>
      );
    }

    const valueOption = this.options.find(item => item.value === value);

    return (
      <div className={classNames('privacy-dropdown', placement, { active: open })} onKeyDown={this.handleKeyDown}>
        <div className={classNames('privacy-dropdown__value', { active: this.options.indexOf(valueOption) === (placement === 'bottom' ? 0 : (this.options.length - 1)) })} ref={this.setTargetRef}>
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
