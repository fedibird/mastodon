import React from 'react';
import PropTypes from 'prop-types';
import { injectIntl, defineMessages } from 'react-intl';
import classNames from 'classnames';
import Overlay from 'react-overlays/Overlay';
import LanguageDropdownMenu from 'mastodon/components/language_dropdown_menu';
import TextIconButton from './text_icon_button';

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
  };

  static defaultProps = {
    frequentlyUsedLanguages: [],
  };

  state = {
    open: false,
    placement: 'bottom',
  };

  handleToggle = () => {
    if (this.state.open && this.activeElement) {
      this.activeElement.focus({ preventScroll: true });
    } else if (!this.state.open) {
      this.activeElement = document.activeElement;
    }

    this.setState({ open: !this.state.open });
  };

  handleClose = (language) => {
    const { value, onClose } = this.props;

    if (this.state.open && this.activeElement) {
      this.activeElement.focus({ preventScroll: true });
    }

    this.setState({ open: false });

    if (onClose) {
      onClose(language || value);
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

  render () {
    const { value, intl, frequentlyUsedLanguages } = this.props;
    const { open, placement } = this.state;

    return (
      <div className={classNames('privacy-dropdown', 'language-dropdown', placement, { active: open })}>
        <div className='privacy-dropdown__value' ref={this.setTargetRef}>
          <TextIconButton
            label={value ? value.toUpperCase() : ''}
            title={intl.formatMessage(messages.changeLanguage)}
            active={open}
            onClick={this.handleToggle}
          />
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
