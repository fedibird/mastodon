import React from 'react';
import PropTypes from 'prop-types';
import Overlay from 'react-overlays/Overlay';
import IconButton from '../../../components/icon_button';

export default class ComposerOverflowMenu extends React.PureComponent {

  static propTypes = {
    label: PropTypes.string.isRequired,
    children: PropTypes.node,
  };

  state = {
    open: false,
  };

  target = null;

  panel = null;

  setTarget = (node) => {
    this.target = node;
  };

  setPanel = (node) => {
    this.panel = node;
  };

  findTarget = () => this.target;

  componentDidMount () {
    document.addEventListener('mousedown', this.handleDocumentClick);
    document.addEventListener('keydown', this.handleDocumentKey);
  }

  componentWillUnmount () {
    document.removeEventListener('mousedown', this.handleDocumentClick);
    document.removeEventListener('keydown', this.handleDocumentKey);
  }

  handleDocumentClick = (event) => {
    if (!this.state.open) {
      return;
    }

    if (this.target && this.target.contains(event.target)) {
      return;
    }

    if (this.panel && this.panel.contains(event.target)) {
      return;
    }

    this.setState({ open: false });
  };

  handleDocumentKey = (event) => {
    if (event.key === 'Escape' && this.state.open) {
      this.setState({ open: false });
    }
  };

  handleToggle = () => {
    this.setState(state => ({ open: !state.open }));
  };

  render () {
    const { open } = this.state;

    return (
      <div className='compose-form__overflow' ref={this.setTarget}>
        <IconButton
          className='compose-form__overflow-button'
          icon='ellipsis-h'
          title={this.props.label}
          onClick={this.handleToggle}
          expanded={open}
          inverted
        />
        <Overlay show={open} placement='top' flip target={this.findTarget} popperConfig={{ strategy: 'fixed' }}>
          {({ props, placement }) => (
            <div {...props} ref={this.setPanel} className={`compose-form__overflow-panel ${placement || ''}`} data-testid='composer-overflow-menu'>
              {this.props.children}
            </div>
          )}
        </Overlay>
      </div>
    );
  }

}
