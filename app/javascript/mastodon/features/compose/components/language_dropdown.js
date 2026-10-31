import React from 'react';
import PropTypes from 'prop-types';
import { injectIntl, defineMessages } from 'react-intl';
import classNames from 'classnames';
import Overlay from 'react-overlays/Overlay';
import LanguageDropdownMenu from 'mastodon/components/language_dropdown_menu';

const messages = defineMessages({
  changeLanguage: { id: 'compose.language.change', defaultMessage: 'Change language' },
});

class LanguageDropdown extends React.PureComponent {

  static propTypes = {
    value: PropTypes.string,
    frequentlyUsedLanguages: PropTypes.arrayOf(PropTypes.string),
    languages: PropTypes.arrayOf(PropTypes.arrayOf(PropTypes.string)),
    intl: PropTypes.object.isRequired,
    onChange: PropTypes.func,
    onClose: PropTypes.func,
    presentation: PropTypes.oneOf(['detached']),
    open: PropTypes.bool,
    onDismiss: PropTypes.func,
    returnFocus: PropTypes.object,
  };

  static defaultProps = {
    frequentlyUsedLanguages: [],
  };

  state = {
    open: false,
    placement: 'bottom',
  };

  handleToggle = (e) => {
    if (e) {
      e.preventDefault();
    }

    if (this.state.open && this.activeElement) {
      this.activeElement.focus({ preventScroll: true });
    } else if (!this.state.open) {
      this.activeElement = document.activeElement;
    }

    this.setState({ open: !this.state.open });
  };

  languageLabel () {
    return (this.props.value || '').toUpperCase();
  }

  handleClose = (language) => {
    const { value, onClose, onDismiss, returnFocus } = this.props;
    const focusTarget = returnFocus || this.activeElement;

    if (focusTarget && typeof focusTarget.focus === 'function') {
      focusTarget.focus({ preventScroll: true });
    }

    this.setState({ open: false });

    if (onClose) {
      onClose(language || value);
    }

    if (onDismiss) {
      onDismiss();
    }
  };

  handleChange = value => {
    const { onChange } = this.props;

    if (onChange) {
      onChange(value);
    }
  };

  setTargetRef = c => {
    this.target = c;
  };

  findTarget = () => {
    return this.target;
  };

  handleOverlayEnter = (state) => {
    this.setState({ placement: state.placement });
  };

  renderDetached () {
    const { value, intl, frequentlyUsedLanguages, open } = this.props;

    return (
      <div className='compose-form__language-anchor' ref={this.setTargetRef}>
        <Overlay show={Boolean(open)} placement='bottom' flip target={this.findTarget} popperConfig={{ strategy: 'fixed', onFirstUpdate: this.handleOverlayEnter }}>
          {({ props, placement }) => (
            <div {...props}>
              <div className={`dropdown-animation language-dropdown__dropdown ${placement}`}>
                <LanguageDropdownMenu
                  value={value}
                  languages={this.props.languages}
                  frequentlyUsedLanguages={frequentlyUsedLanguages}
                  onClose={this.handleClose}
                  onChange={this.handleChange}
                  intl={intl}
                />
              </div>
            </div>
          )}
        </Overlay>
      </div>
    );
  }

  render () {
    if (this.props.presentation === 'detached') {
      return this.renderDetached();
    }

    const { value, intl, frequentlyUsedLanguages } = this.props;
    const { open, placement } = this.state;

    return (
      <div className={classNames('privacy-dropdown', 'language-dropdown', placement, { active: open })}>
        <div className='privacy-dropdown__value' ref={this.setTargetRef}>
          <button
            type='button'
            className={classNames('text-icon-button', { active: open })}
            title={intl.formatMessage(messages.changeLanguage)}
            aria-label={intl.formatMessage(messages.changeLanguage)}
            aria-expanded={open}
            onClick={this.handleToggle}
          >
            {this.languageLabel()}
          </button>
        </div>

        <Overlay show={open} placement={'bottom'} flip target={this.findTarget} popperConfig={{ strategy: 'fixed', onFirstUpdate: this.handleOverlayEnter }}>
          {({ props, placement }) => (
            <div {...props}>
              <div className={`dropdown-animation language-dropdown__dropdown ${placement}`}>
                <LanguageDropdownMenu
                  value={value}
                  languages={this.props.languages}
                  frequentlyUsedLanguages={frequentlyUsedLanguages}
                  onClose={this.handleClose}
                  onChange={this.handleChange}
                  intl={intl}
                />
              </div>
            </div>
          )}
        </Overlay>
      </div>
    );
  }

}

export default injectIntl(LanguageDropdown);
