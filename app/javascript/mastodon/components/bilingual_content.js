import React from 'react';
import PropTypes from 'prop-types';
import { pairTranslationBlocks } from 'mastodon/utils/translation_blocks';

export default class BilingualContent extends React.PureComponent {

  static propTypes = {
    className: PropTypes.string,
    sourceHtml: PropTypes.string,
    targetHtml: PropTypes.string,
    sourceLang: PropTypes.string,
    targetLang: PropTypes.string,
    tabIndex: PropTypes.oneOfType([PropTypes.number, PropTypes.string]),
  };

  render () {
    const { className, sourceHtml, targetHtml, sourceLang, targetLang, tabIndex } = this.props;
    const pairs = pairTranslationBlocks(sourceHtml || '', targetHtml || '', sourceLang || '', targetLang || '');

    return (
      <div className={className} tabIndex={tabIndex}>
        {pairs.map((pair, index) => (
          <div className='status-translation-pair' key={index}>
            <div
              className='status-translation-pair__source'
              dangerouslySetInnerHTML={{ __html: pair.sourceHtml }}
            />
            {!pair.omitTarget && (
              <div
                className='status-translation-pair__target'
                dangerouslySetInnerHTML={{ __html: pair.targetHtml }}
              />
            )}
          </div>
        ))}
      </div>
    );
  }

}
