import React from 'react';
import PropTypes from 'prop-types';
import initialState from 'mastodon/initial_state_data';

const autoPlayEmoji = initialState?.meta?.auto_play_emoji;

// The registration list has a fixed image-frame height and a capped natural
// width. Picker bodies keep their normal square cells.
export default class EmojiArt extends React.PureComponent {

  static propTypes = {
    image: PropTypes.object,
    text: PropTypes.string,
    size: PropTypes.number,
    wide: PropTypes.bool,
  };

  static defaultProps = { size: 24, wide: false, text: '…' };

  state = { failed: false, src: null };

  static getDerivedStateFromProps(props, state) {
    const src = props.image && (autoPlayEmoji && props.image.animatedSrc || props.image.src);

    return src !== state.src ? { src, failed: false } : null;
  }

  handleError = () => this.setState({ failed: true });

  render() {
    const { text, size, wide } = this.props;
    const { src, failed } = this.state;

    return (
      <span className={`pes-art${wide ? ' pes-art--wide' : ''}`} style={{ height: size, minWidth: size, width: wide ? undefined : size }} aria-hidden='true'>
        {src && !failed ? (
          <img src={src} alt='' draggable='false' onError={this.handleError} style={{ height: size, width: wide ? 'auto' : size }} />
        ) : (
          <span className='pes-initial'>{text}</span>
        )}
      </span>
    );
  }

}
