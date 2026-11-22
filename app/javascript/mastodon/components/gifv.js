import React from 'react';
import PropTypes from 'prop-types';
import { bindEmojiMuteElementSource } from 'mastodon/features/emoji/emoji_mute_sources';

export default class GIFV extends React.PureComponent {

  static propTypes = {
    src: PropTypes.string.isRequired,
    alt: PropTypes.string,
    emojiMuteSource: PropTypes.string,
    lang: PropTypes.string,
    width: PropTypes.number,
    height: PropTypes.number,
    onClick: PropTypes.func,
  };

  state = {
    loading: true,
  };

  handleLoadedData = () => {
    this.setState({ loading: false });
  }

  bindEmojiMuteSource = node => {
    if (node && typeof this.props.emojiMuteSource === 'string') {
      bindEmojiMuteElementSource(node, this.props.emojiMuteSource);
    }
  }

  componentWillReceiveProps (nextProps) {
    if (nextProps.src !== this.props.src) {
      this.setState({ loading: true });
    }
  }

  handleClick = e => {
    const { onClick } = this.props;

    if (onClick) {
      e.stopPropagation();
      onClick();
    }
  }

  render () {
    const { src, width, height, alt, lang } = this.props;
    const { loading } = this.state;

    return (
      <div className='gifv' style={{ position: 'relative' }}>
        {loading && (
          <canvas
            width={width}
            height={height}
            role='button'
            tabIndex='0'
            aria-label={alt}
            title={alt}
            lang={lang}
            ref={this.bindEmojiMuteSource}
            onClick={this.handleClick}
          />
        )}

        <video
          src={src}
          role='button'
          tabIndex='0'
          aria-label={alt}
          title={alt}
          lang={lang}
          ref={this.bindEmojiMuteSource}
          muted
          loop
          autoPlay
          playsInline
          onClick={this.handleClick}
          onLoadedData={this.handleLoadedData}
          style={{ position: loading ? 'absolute' : 'static', top: 0, left: 0 }}
        />
      </div>
    );
  }

}
