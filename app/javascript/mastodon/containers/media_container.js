import React, { PureComponent, Fragment } from 'react';
import ReactDOM from 'react-dom';
import PropTypes from 'prop-types';
import { IntlProvider, addLocaleData } from 'react-intl';
import { fromJS } from 'immutable';
import { getLocale } from 'mastodon/locales';
import { getScrollbarWidth } from 'mastodon/utils/scrollbar';
import MediaGallery from 'mastodon/components/media_gallery';
import Poll from 'mastodon/components/poll';
import Hashtag from 'mastodon/components/hashtag';
import ModalRoot from 'mastodon/components/modal_root';
import MediaModal from 'mastodon/features/ui/components/media_modal';
import Video from 'mastodon/features/video';
import Card from 'mastodon/features/status/components/card';
import Audio from 'mastodon/features/audio';
import PublicStatusHistory from 'mastodon/components/public_status_history';
import StatusHistoryRevision from 'mastodon/components/status_history_revision';

const { localeData, messages } = getLocale();
addLocaleData(localeData);

const MEDIA_COMPONENTS = { MediaGallery, Video, Card, Poll, Hashtag, Audio, StatusHistory: PublicStatusHistory };

export default class MediaContainer extends PureComponent {

  static propTypes = {
    locale: PropTypes.string.isRequired,
    components: PropTypes.object.isRequired,
  };

  state = {
    media: null,
    index: null,
    time: null,
    backgroundColor: null,
    options: null,
    historyRevision: null,
    historyLanguage: null,
  };

  lockScroll = () => {
    document.body.classList.add('with-modals--active');
    document.documentElement.style.marginRight = `${getScrollbarWidth()}px`;
  }

  handleOpenMedia = (media, index) => {
    this.lockScroll();

    this.setState({ media, index, historyRevision: null, historyLanguage: null });
  }

  handleOpenVideo = (options) => {
    const { components } = this.props;
    const { media } = JSON.parse(components[options.componetIndex].getAttribute('data-props'));
    const mediaList = fromJS(media);

    this.lockScroll();

    this.setState({ media: mediaList, options, historyRevision: null, historyLanguage: null });
  }

  handleOpenHistoryRevision = (revision, language) => {
    this.lockScroll();

    this.setState({
      media: null,
      index: null,
      options: null,
      historyRevision: revision,
      historyLanguage: language,
    });
  }

  handleCloseMedia = () => {
    document.body.classList.remove('with-modals--active');
    document.documentElement.style.marginRight = 0;

    this.setState({
      media: null,
      index: null,
      time: null,
      backgroundColor: null,
      options: null,
      historyRevision: null,
      historyLanguage: null,
    });
  }

  setBackgroundColor = color => {
    this.setState({ backgroundColor: color });
  }

  render () {
    const { locale, components } = this.props;

    return (
      <IntlProvider locale={locale} messages={messages}>
        <Fragment>
          {[].map.call(components, (component, i) => {
            const componentName = component.getAttribute('data-component');
            const Component = MEDIA_COMPONENTS[componentName];
            const { media, card, poll, hashtag, ...props } = JSON.parse(component.getAttribute('data-props'));

            Object.assign(props, {
              ...(media   ? { media:   fromJS(media)   } : {}),
              ...(card    ? { card:    fromJS(card)    } : {}),
              ...(poll    ? { poll:    fromJS(poll)    } : {}),
              ...(hashtag ? { hashtag: fromJS(hashtag) } : {}),

              ...(componentName === 'Video' ? {
                componetIndex: i,
                onOpenVideo: this.handleOpenVideo,
              } : {
                onOpenMedia: this.handleOpenMedia,
              }),
              ...(componentName === 'StatusHistory' ? {
                onOpenRevision: this.handleOpenHistoryRevision,
              } : {}),
            });

            return ReactDOM.createPortal(
              <Component {...props} key={`media-${i}`} />,
              component,
            );
          })}

          <ModalRoot backgroundColor={this.state.backgroundColor} onClose={this.handleCloseMedia}>
            {this.state.media && (
              <MediaModal
                media={this.state.media}
                index={this.state.index || 0}
                currentTime={this.state.options?.startTime}
                autoPlay={this.state.options?.autoPlay}
                volume={this.state.options?.defaultVolume}
                onClose={this.handleCloseMedia}
                onChangeBackgroundColor={this.setBackgroundColor}
              />
            )}
            {!this.state.media && this.state.historyRevision && (
              <StatusHistoryRevision
                revision={this.state.historyRevision}
                account={this.state.historyRevision.get('account')}
                language={this.state.historyLanguage}
                onClose={this.handleCloseMedia}
              />
            )}
          </ModalRoot>
        </Fragment>
      </IntlProvider>
    );
  }

}
