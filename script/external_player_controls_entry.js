import React from 'react';
import ReactDOM from 'react-dom';
import { IntlProvider, addLocaleData } from 'react-intl';
import jaLocaleData from 'react-intl/locale-data/ja';
import { createStore } from 'redux';
import { Provider } from 'react-redux';
import { Map as ImmutableMap, fromJS } from 'immutable';

import ExternalEmbedPlayer from 'mastodon/components/external_embed_player';
import ExternalRemoteMedia from 'mastodon/components/external_remote_media';
import ExternalPlayerDock from 'mastodon/external_player/dock';
import ja from 'mastodon/locales/ja.json';

addLocaleData(jaLocaleData);

const store = createStore(() => ImmutableMap({ picture_in_picture: {} }));
const audioUrl = window.__PLAYER_AUDIO__;
const videoUrl = window.__PLAYER_VIDEO__;
const frameUrl = window.__PLAYER_FRAME__;

const audioStatus = fromJS({
  id: 'post-audio',
  fedibird_external: {
    media: [{ id: 'talk', type: 'audio', url: audioUrl, description: 'Weekly signal' }],
  },
});

const videoStatus = fromJS({
  id: 'post-video',
  fedibird_external: {
    media: [{ id: 'clip', type: 'video', url: videoUrl, description: 'Field notes' }],
  },
});

const Page = () => (
  <Provider store={store}>
    <IntlProvider locale='ja' messages={ja}>
      <div className='fixture'>
        <section className='demo-card demo-card--light' id='compare-light'>
          <h1>Fictional feed, light background</h1>
          <p className='demo-label'>Previous audio background</p>
          <audio className='demo-audio demo-audio--old' controls src={audioUrl} />
          <p className='demo-label'>Current audio background</p>
          <audio className='demo-audio demo-audio--new external-player-host__media external-player-host__media--audio' controls src={audioUrl} />
        </section>
        <section className='demo-card demo-card--dark' id='compare-dark'>
          <h1>Fictional feed, dark background</h1>
          <p className='demo-label'>Previous audio background</p>
          <audio className='demo-audio demo-audio--old' controls src={audioUrl} />
          <p className='demo-label'>Current audio background</p>
          <audio className='demo-audio demo-audio--new external-player-host__media external-player-host__media--audio' controls src={audioUrl} />
        </section>
        <div className='column' id='column'>
          <article className='status' id='audio-post'>
            <h2>Example Station</h2>
            <p>A fictional note. The native audio control stays clear of the icons.</p>
            <ExternalRemoteMedia status={audioStatus} statusId='post-audio' />
          </article>
          <article className='status' id='video-post'>
            <h2>Example Station</h2>
            <p>A fictional clip. Pop out sits on the outer edge.</p>
            <ExternalRemoteMedia status={videoStatus} statusId='post-video' />
          </article>
          <article className='status' id='frame-post'>
            <h2>Example Station</h2>
            <p>A fictional embedded player.</p>
            <ExternalEmbedPlayer
              statusId='post-frame'
              entry={{ id: 'embed-1', url: frameUrl, duration: 61 }}
              articleUrl='https://example.test/article'
            />
          </article>
        </div>
        <video className='external-player-host__media external-player-host__media--video' id='video-swatch' />
        <ExternalPlayerDock />
      </div>
    </IntlProvider>
  </Provider>
);

ReactDOM.render(<Page />, document.getElementById('app'));
