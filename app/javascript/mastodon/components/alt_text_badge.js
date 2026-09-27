import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import Overlay from 'react-overlays/Overlay';
import { languages as preloadedLanguages } from 'mastodon/initial_state';

const languageLabel = code => {
  if (!code) {
    return '';
  }

  const language = (preloadedLanguages || []).find(lang => lang[0] === code);
  return language ? language[2] : code;
};

const offset = [0, 4];
const popperConfig = { strategy: 'fixed' };

class AltTextBadge extends React.PureComponent {

  static propTypes = {
    description: PropTypes.string,
    originalDescription: PropTypes.string,
    translatedDescription: PropTypes.string,
    sourceLang: PropTypes.string,
    targetLang: PropTypes.string,
    mode: PropTypes.oneOf(['original', 'translated', 'bilingual']),
  };

  state = {
    open: false,
    clientX: null,
    clientY: null,
  };

  handleClick = () => {
    this.setState({ open: true });
  }

  handleClose = () => {
    this.setState({ open: false });
  }

  handleMouseDown = (e) => {
    this.setState({ clientX: e.clientX, clientY: e.clientY });
  }

  handleMouseUp = (e) => {
    const maxDelta = 5;
    const {clientX: startX, clientY: startY} = this.state;

    if (startX == null) {
      return;
    }

    const [deltaX, deltaY] = [
      Math.abs(e.clientX - startX),
      Math.abs(e.clientY - startY),
    ];

    let element = e.target;

    while (element && element instanceof HTMLElement) {
      if (
        element.localName === 'button' ||
        element.localName === 'a' ||
        element.localName === 'label'
      ) {
        return;
      }

      element = element.parentNode;
    }

    if (
      deltaX + deltaY < maxDelta &&
      (e.button === 0 || e.button === 1) &&
      e.detail >= 1
    ) {
      this.handleClose(e);
    }

    this.setState({ clientX: null, clientY: null });
  }

  setRef = (c) => {
    this.node = c;
  }

  render () {
    const { open } = this.state;
    const original = this.props.originalDescription ?? this.props.description ?? '';
    const translated = this.props.translatedDescription || '';
    const mode = this.props.mode || (translated ? 'translated' : 'original');
    const sourceLang = this.props.sourceLang || '';
    const targetLang = this.props.targetLang || '';
    const showBilingual = mode === 'bilingual' && original && translated;
    const showTranslated = mode !== 'original' && translated;
    const shown = showTranslated ? translated : original;
    const shownLang = showTranslated ? (targetLang || sourceLang) : sourceLang;
    const languageMeta = translated && sourceLang && targetLang
      ? `${languageLabel(sourceLang)} → ${languageLabel(targetLang)}`
      : '';

    return (
      <>
        <button
          ref={this.setRef}
          className='media-gallery__alt__label'
          onClick={this.handleClick}
          aria-expanded={open}
        >
          ALT
        </button>

        <Overlay
          rootClose
          onHide={this.handleClose}
          show={open}
          target={this.node}
          placement='top-end'
          flip
          offset={offset}
          popperConfig={popperConfig}
        >
          {({ props }) => (
            <div {...props} className='hover-card-controller'>
              <div
                className='media-gallery__alt__popover dropdown-animation'
                role='region'
                onMouseDown={this.handleMouseDown}
                onMouseUp={this.handleMouseUp}
              >
                <h4>
                  <FormattedMessage
                    id='alt_text_badge.title'
                    defaultMessage='Alt text'
                  />
                </h4>
                {languageMeta && (
                  <p className='media-gallery__alt__meta'>{languageMeta}</p>
                )}
                {showBilingual ? (
                  <React.Fragment>
                    <p className='status-translation-pair__source' lang={sourceLang} dir='auto'>{original}</p>
                    <p className='status-translation-pair__target' lang={targetLang} dir='auto'>{translated}</p>
                  </React.Fragment>
                ) : (
                  <p lang={shownLang || undefined} dir='auto'>{shown}</p>
                )}
              </div>
            </div>
          )}
        </Overlay>
      </>
    );
  };

}

export default AltTextBadge;
