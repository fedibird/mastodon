import React from 'react';
import PropTypes from 'prop-types';

const iconStyle = {
  height: null,
  lineHeight: '27px',
  width: `${18 * 1.28571429}px`,
};

export default class TextIconButton extends React.PureComponent {

  static propTypes = {
    label: PropTypes.string.isRequired,
    title: PropTypes.string,
    active: PropTypes.bool,
    onClick: PropTypes.func.isRequired,
    ariaControls: PropTypes.string,
    presentation: PropTypes.oneOf(['menu']),
    onMenuClose: PropTypes.func,
  };

  handleClick = (e) => {
    e.preventDefault();
    this.props.onClick();

    if (this.props.onMenuClose) {
      this.props.onMenuClose();
    }
  }

  render () {
    const { label, title, active, ariaControls } = this.props;

    if (this.props.presentation === 'menu') {
      return (
        <button
          type='button'
          title={title}
          aria-label={title}
          className='compose-form__menu-row'
          aria-pressed={Boolean(active)}
          onClick={this.handleClick}
        >
          {label}
        </button>
      );
    }

    return (
      <button
        title={title}
        aria-label={title}
        className={`text-icon-button ${active ? 'active' : ''}`}
        aria-expanded={active}
        onClick={this.handleClick}
        aria-controls={ariaControls} style={iconStyle}
      >
        {label}
      </button>
    );
  }

}
