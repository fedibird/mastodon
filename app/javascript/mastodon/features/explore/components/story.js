import React, { PureComponent } from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import classNames from 'classnames';

import Blurhash from 'mastodon/components/blurhash';
import { withEmojiMuteTextIndex } from 'mastodon/components/emoji_muted_html';
import RelativeTimestamp from 'mastodon/components/relative_timestamp';
import ShortNumber from 'mastodon/components/short_number';
import { presentEmojiMutePlain } from 'mastodon/features/emoji/emoji_mute_text';
import { bindEmojiMuteElementSource, forgetEmojiMuteAttributeSource, rememberEmojiMuteAttributeSource } from 'mastodon/features/emoji/emoji_mute_sources';

const accountsCountRenderer = (displayNumber, pluralReady) => (
  <FormattedMessage
    id='trends.counter_by_accounts'
    defaultMessage='{count, plural, one {{counter} person} other {{counter} people}} talking'
    values={{ count: pluralReady, counter: <strong>{displayNumber}</strong> }}
  />
);

const shownPlain = (value, index) => (
  typeof value === 'string' ? presentEmojiMutePlain(value, index) : value
);

class Story extends PureComponent {

  static propTypes = {
    url: PropTypes.string.isRequired,
    title: PropTypes.string,
    lang: PropTypes.string,
    publisher: PropTypes.string,
    publishedAt: PropTypes.string,
    author: PropTypes.string,
    sharedTimes: PropTypes.number.isRequired,
    thumbnail: PropTypes.string,
    thumbnailDescription: PropTypes.string,
    blurhash: PropTypes.string,
    expanded: PropTypes.bool,
    emojiMuteTextIndex: PropTypes.object,
  };

  state = {
    thumbnailLoaded: false,
  };

  componentDidMount() {
    this.bindSources();
  }

  componentDidUpdate() {
    this.bindSources();
  }

  setRoot = (node) => {
    this.root = node;
  };

  bindSources() {
    if (!this.root) {
      return;
    }

    const { title, publisher, author, thumbnailDescription } = this.props;

    bindEmojiMuteElementSource(this.root.querySelector('.story__details__title'), typeof title === 'string' ? title : '');
    bindEmojiMuteElementSource(this.root.querySelector('.story__details__publisher > span'), typeof publisher === 'string' ? publisher : '');

    const authorNode = this.root.querySelector('.story__details__author');

    if (authorNode && typeof author === 'string') {
      bindEmojiMuteElementSource(authorNode, author);
    }

    const image = this.root.querySelector('img');

    if (!image) {
      return;
    }

    const description = typeof thumbnailDescription === 'string' ? thumbnailDescription : '';

    rememberEmojiMuteAttributeSource(image, 'alt', description);

    if (typeof thumbnailDescription === 'string') {
      rememberEmojiMuteAttributeSource(image, 'title', thumbnailDescription);
    } else {
      forgetEmojiMuteAttributeSource(image, 'title');
    }
  }

  handleImageLoad = () => this.setState({ thumbnailLoaded: true });

  render () {
    const { expanded, url, title, lang, publisher, author, publishedAt, sharedTimes, thumbnail, thumbnailDescription, blurhash, emojiMuteTextIndex } = this.props;
    const { thumbnailLoaded } = this.state;
    const shownTitle = shownPlain(title, emojiMuteTextIndex);
    const shownPublisher = shownPlain(publisher, emojiMuteTextIndex);
    const shownAuthor = shownPlain(author, emojiMuteTextIndex);
    const shownDescription = shownPlain(thumbnailDescription, emojiMuteTextIndex);

    return (
      <a className={classNames('story', { expanded })} href={url} target='_blank' rel='noopener noreferrer' ref={this.setRoot}>
        <div className='story__details'>
          <div className='story__details__publisher'>
            <span lang={lang}>{shownPublisher}</span>
            {publishedAt && <> · <RelativeTimestamp timestamp={publishedAt} /></>}
          </div>
          <div className='story__details__title' lang={lang}>{shownTitle}</div>
          <div className='story__details__shared'>
            {author && <><FormattedMessage id='link_preview.author' defaultMessage='By {name}' values={{ name: <strong className='story__details__author'>{shownAuthor}</strong> }} /> · </>}
            <ShortNumber value={sharedTimes} renderer={accountsCountRenderer} />
          </div>
        </div>

        <div className='story__thumbnail'>
          {thumbnail ? (
            <>
              {blurhash && (
                <div className={classNames('story__thumbnail__preview', { 'story__thumbnail__preview--hidden': thumbnailLoaded })}>
                  <Blurhash hash={blurhash} />
                </div>
              )}
              <img src={thumbnail} onLoad={this.handleImageLoad} alt={shownDescription || ''} title={shownDescription} lang={lang} />
            </>
          ) : <div className='story__thumbnail__placeholder' />}
        </div>
      </a>
    );
  }

}

export default withEmojiMuteTextIndex(Story);
