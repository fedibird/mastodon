import React from 'react';
import PropTypes from 'prop-types';
import Overlay from 'react-overlays/Overlay';
import IconButton from '../../../components/icon_button';
import { createOverlayRefBridge } from '../overlay_ref';

export default class ComposerOverflowMenu extends React.PureComponent {

  static propTypes = {
    label: PropTypes.string.isRequired,
    children: PropTypes.node,
    closeToken: PropTypes.number,
  };

  state = {
    open: false,
  };

  target = null;

  menuBridge = createOverlayRefBridge();

  setTarget = (node) => {
    this.target = node;
  };

  findTarget = () => this.target;

  renderPanel = ({ props, placement }) => {
    const { ref: popperRef, style, ...overlayProps } = props;

    this.menuBridge.syncPopperRef(popperRef);

    return (
      <div
        {...overlayProps}
        ref={this.menuBridge.compose}
        style={style}
        className={`compose-form__overflow-panel ${placement || ''}`}
        data-testid='composer-overflow-menu'
      >
        {this.props.children}
      </div>
    );
  };

  componentDidUpdate (prevProps) {
    if (prevProps.closeToken !== this.props.closeToken && this.state.open) {
      this.setState({ open: false });
    }
  }

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

    const panel = this.menuBridge.getNode();

    if (panel && panel.contains(event.target)) {
      return;
    }

    this.setState({ open: false });
  };

  handleDocumentKey = (event) => {
    if (event.key === 'Escape' && this.state.open) {
      event.preventDefault();
      this.setState({ open: false }, () => {
        const button = this.target && this.target.querySelector('button');

        if (button) {
          button.focus();
        }
      });
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
          {this.renderPanel}
        </Overlay>
      </div>
    );
  }

}
