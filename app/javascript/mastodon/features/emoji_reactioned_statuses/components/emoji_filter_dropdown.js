import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import Overlay from 'react-overlays/Overlay';
import EmojiFilterBar from './emoji_filter_bar';
import EmojiReactionFilterPicker from './emoji_filter_picker';

let sequence = 0;

const popperConfig = {
  strategy: 'fixed',
  modifiers: [
    {
      name: 'preventOverflow',
      options: {
        boundary: 'viewport',
        altAxis: true,
        padding: 8,
      },
    },
    {
      name: 'flip',
      options: {
        boundary: 'viewport',
        padding: 8,
      },
    },
  ],
};

export default class EmojiFilterDropdown extends React.PureComponent {

  static propTypes = {
    columnId: PropTypes.string,
    emojis: PropTypes.oneOfType([ImmutablePropTypes.list, PropTypes.array]),
    preferredEmojis: PropTypes.oneOfType([ImmutablePropTypes.list, PropTypes.array]),
    catalogItems: PropTypes.oneOfType([ImmutablePropTypes.list, PropTypes.array]),
    isLoading: PropTypes.bool,
    loaded: PropTypes.bool,
    error: PropTypes.any,
    openDropdownId: PropTypes.string,
    modalType: PropTypes.string,
    modalColumnId: PropTypes.string,
    onOpen: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    onApply: PropTypes.func.isRequired,
    onChange: PropTypes.func.isRequired,
    onTogglePreferred: PropTypes.func.isRequired,
  };

  state = {
    id: `emoji-reaction-filter:${++sequence}`,
  };

  componentDidUpdate(prevProps) {
    const wasOpen = prevProps.openDropdownId === this.state.id;
    const isOpen = this.props.openDropdownId === this.state.id;

    if (isOpen && !wasOpen) {
      document.addEventListener('click', this.handleDocumentClick, false);
    } else if (!isOpen && wasOpen) {
      document.removeEventListener('click', this.handleDocumentClick, false);
    }
  }

  componentWillUnmount() {
    document.removeEventListener('click', this.handleDocumentClick, false);

    if (this.props.openDropdownId === this.state.id || this.isModalOpen()) {
      this.props.onClose(this.state.id);
    }
  }

  setTargetRef = (node) => {
    this.target = node;
  };

  setPickerRef = (node) => {
    this.pickerNode = node;
  };

  findTarget = () => this.target;

  sameColumn(modalColumnId) {
    return (modalColumnId || null) === (this.props.columnId || null);
  }

  isDropdownOpen() {
    return this.props.openDropdownId === this.state.id;
  }

  isModalOpen() {
    return this.props.modalType === 'EMOJI_REACTION_FILTER' && this.sameColumn(this.props.modalColumnId);
  }

  handleOpen = (event) => {
    if (this.isDropdownOpen() || this.isModalOpen()) {
      this.handleClose();
      return;
    }

    const keyboard = !event || event.type !== 'click' || event.detail === 0;
    this.props.onOpen(this.state.id, keyboard);
  };

  handleTriggerMouseDown = (event) => {
    this.activeElement = event.currentTarget;
  };

  handleClose = () => {
    if (this.activeElement && typeof this.activeElement.focus === 'function') {
      this.activeElement.focus({ preventScroll: true });
      this.activeElement = null;
    }

    this.props.onClose(this.state.id);
  };

  handleDocumentClick = (event) => {
    const target = event.target;

    if (this.pickerNode && this.pickerNode.contains(target)) {
      return;
    }

    if (this.target && this.target.contains(target)) {
      return;
    }

    this.handleClose();
  };

  handleApply = (draft) => {
    this.props.onApply(draft);
    this.handleClose();
  };

  handleBarChange = (next) => {
    this.props.onChange(next);

    if (this.isDropdownOpen() || this.isModalOpen()) {
      this.handleClose();
    }
  };

  renderPicker = ({ props }) => {
    const className = ['emoji-reaction-filter-popover', props.className].filter(Boolean).join(' ');

    return (
      <div {...props} className={className}>
        <div className='emoji-reaction-filter-popover__panel' ref={this.setPickerRef}>
          <EmojiReactionFilterPicker
            catalogItems={this.props.catalogItems}
            appliedEmojis={this.props.emojis}
            preferredEmojis={this.props.preferredEmojis}
            isLoading={this.props.isLoading}
            loaded={this.props.loaded}
            error={this.props.error}
            onApply={this.handleApply}
            onClose={this.handleClose}
            onTogglePreferred={this.props.onTogglePreferred}
          />
        </div>
      </div>
    );
  };

  render() {
    const open = this.isDropdownOpen();

    return (
      <div className='emoji-reaction-filter-dropdown' ref={this.setTargetRef}>
        <EmojiFilterBar
          emojis={this.props.emojis}
          catalogItems={this.props.catalogItems}
          expanded={open || this.isModalOpen()}
          onOpen={this.handleOpen}
          onChange={this.handleBarChange}
          onTriggerMouseDown={this.handleTriggerMouseDown}
        />
        {open && (
          <Overlay show offset={[5, 5]} placement='bottom' flip target={this.findTarget} popperConfig={popperConfig}>
            {this.renderPicker}
          </Overlay>
        )}
      </div>
    );
  }

}
