import { act, fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

import ExternalStatusMedia from '../../components/external_status_media';
import {
  IFRAME_ALLOW,
  IFRAME_REFERRER_POLICY,
  IFRAME_SANDBOX,
  applyExternalFeedControl,
  closeSession,
  connectedPlayerNodes,
  endAllExternalPlayers,
  externalPlayerKey,
  getPinnedKey,
  getSessionByIdentity,
  openSession,
  pinSession,
  playbackSnapshot,
  reduceExternalPlayerAction,
  registerAnchor,
  resetExternalPlayersForTests,
  setAttachmentFloatActive,
  unpinSession,
  unregisterAnchor,
} from '../session';

jest.mock('react-intl', () => ({
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/media_gallery', () => () => null);
jest.mock('mastodon/features/video', () => () => null);
jest.mock('mastodon/features/audio', () => () => null);

const PLAYER = 'https://player.example/embed/fixture';
const CLIP = 'https://cdn.example/clip.mp4';
const TALK = 'https://cdn.example/talk.mp3';

const embedStatus = (id = '10') => fromJS({
  id,
  fedibird_external: {
    canonical_url: 'https://watch.example/article',
    sequence: [
      { id: 'embed-1', type: 'embed', delivery: 'remote', url: PLAYER, duration: 61 },
    ],
  },
});

const remoteStatus = (id, media) => fromJS({
  id,
  fedibird_external: { media },
});

afterEach(() => {
  resetExternalPlayersForTests();
});

describe('external player sessions', () => {
  it('keeps one iframe for a status and media id and does not create it before open', () => {
    expect(externalPlayerKey('10', 'embed-1')).not.toBe(externalPlayerKey('10', 'embed-2'));
    expect(connectedPlayerNodes('iframe')).toHaveLength(0);
    expect(document.body.innerHTML).not.toContain(PLAYER);

    const first = openSession({ statusId: '10', mediaId: 'embed-1', kind: 'iframe', url: PLAYER });
    const second = openSession({ statusId: '10', mediaId: 'embed-1', kind: 'iframe', url: PLAYER });
    const other = openSession({ statusId: '10', mediaId: 'embed-2', kind: 'iframe', url: 'https://player.example/embed/other' });

    expect(first.node).toBe(second.node);
    expect(other.node).not.toBe(first.node);
    expect(first.node.parentElement.id).toBe('external-player-host');
    expect(first.node.getAttribute('src')).toBe(PLAYER);
    expect(first.node.getAttribute('sandbox')).toBe(IFRAME_SANDBOX);
    expect(first.node.getAttribute('sandbox')).not.toContain('allow-top-navigation');
    expect(first.node.getAttribute('allow')).toBe(IFRAME_ALLOW);
    expect(first.node.getAttribute('allow')).not.toContain('autoplay');
    expect(first.node.getAttribute('referrerpolicy')).toBe(IFRAME_REFERRER_POLICY);
    expect(first.node.hasAttribute('autoplay')).toBe(false);
    expect(connectedPlayerNodes('iframe')).toHaveLength(2);
  });

  it('pins by repositioning the same node and ends the previous pinned session', () => {
    const audio = openSession({ statusId: '1', mediaId: 'talk', kind: 'audio', url: TALK });
    const video = openSession({ statusId: '2', mediaId: 'clip', kind: 'video', url: CLIP });
    const anchor = document.createElement('div');
    document.body.appendChild(anchor);
    const anchorId = registerAnchor({ key: audio.key, element: anchor, prefer: true, releaseMode: () => 'detach' });
    audio.node.volume = 0.35;
    audio.node.playbackRate = 1.25;
    audio.node.muted = true;
    const play = jest.spyOn(audio.node, 'play').mockImplementation(() => Promise.resolve());

    audio.node.dispatchEvent(new Event('play'));
    expect(pinSession(audio.key).ok).toBe(true);
    expect(getPinnedKey()).toBe(audio.key);
    expect(playbackSnapshot(audio.key)).toEqual(expect.objectContaining({
      pinned: true,
      parentId: 'external-player-host',
      src: TALK,
      volume: 0.35,
      playbackRate: 1.25,
      muted: true,
      userStarted: true,
      paused: false,
    }));
    expect(play).not.toHaveBeenCalled();

    const audioNode = audio.node;
    pinSession(video.key);
    expect(getSessionByIdentity('1', 'talk')).toBeNull();
    expect(getPinnedKey()).toBe(video.key);
    expect(audioNode.isConnected).toBe(false);
    expect(video.node.isConnected).toBe(true);
    expect(video.node.getAttribute('src')).toBe(CLIP);

    unregisterAnchor(anchorId);
    anchor.remove();
  });

  it('does not return a pinned player when its row is gone', () => {
    const session = openSession({ statusId: '4', mediaId: 'embed-1', kind: 'iframe', url: PLAYER });
    pinSession(session.key);

    expect(unpinSession(session.key)).toEqual({ returned: false, reason: 'missing-anchor' });
    expect(getPinnedKey()).toBe(session.key);
    expect(playbackSnapshot(session.key).returnUnavailable).toBe(true);
    expect(session.node.isConnected).toBe(true);

    const anchor = document.createElement('div');
    document.body.appendChild(anchor);
    registerAnchor({ key: session.key, element: anchor, prefer: true, releaseMode: () => 'detach' });

    expect(unpinSession(session.key).returned).toBe(true);
    expect(getPinnedKey()).toBeNull();
    expect(session.node.isConnected).toBe(true);
    expect(session.node.getAttribute('src')).toBe(PLAYER);
    anchor.remove();
  });

  it('auto-continues only remote media that the user started and has not paused or finished', () => {
    const cases = [
      { events: ['play'], pins: true },
      { events: ['play', 'pause'], pins: false },
      { events: ['play', 'ended'], pins: false },
      { events: [], pins: false },
    ];

    cases.forEach((entry, index) => {
      const session = openSession({ statusId: '8', mediaId: `talk-${index}`, kind: 'audio', url: TALK });
      const anchor = document.createElement('div');
      document.body.appendChild(anchor);
      const play = jest.spyOn(session.node, 'play').mockImplementation(() => Promise.resolve());
      const anchorId = registerAnchor({ key: session.key, element: anchor, prefer: true, releaseMode: () => 'detach' });
      entry.events.forEach(name => session.node.dispatchEvent(new Event(name)));
      unregisterAnchor(anchorId);

      expect(getPinnedKey()).toBe(entry.pins ? session.key : null);
      expect(play).not.toHaveBeenCalled();

      if (!entry.pins) {
        expect(session.node.isConnected).toBe(true);
        expect(session.node.getAttribute('src')).toBe(TALK);
      }

      endAllExternalPlayers('reset-case');
      anchor.remove();
    });
  });

  it('ends an unpinned iframe when its last anchor detaches and keeps a pinned one', async () => {
    const loose = openSession({ statusId: '8', mediaId: 'embed-1', kind: 'iframe', url: PLAYER });
    const looseAnchor = document.createElement('div');
    document.body.appendChild(looseAnchor);
    const looseId = registerAnchor({ key: loose.key, element: looseAnchor, prefer: true, releaseMode: () => 'detach' });
    const looseNode = loose.node;
    unregisterAnchor(looseId);
    await act(async () => {});

    expect(getPinnedKey()).toBeNull();
    expect(getSessionByIdentity('8', 'embed-1')).toBeNull();
    expect(looseNode.isConnected).toBe(false);
    looseAnchor.remove();

    const pinned = openSession({ statusId: '8', mediaId: 'embed-2', kind: 'iframe', url: PLAYER });
    const pinnedAnchor = document.createElement('div');
    document.body.appendChild(pinnedAnchor);
    const pinnedId = registerAnchor({ key: pinned.key, element: pinnedAnchor, prefer: true, releaseMode: () => 'detach' });
    pinSession(pinned.key);
    unregisterAnchor(pinnedId);
    await act(async () => {});

    expect(getPinnedKey()).toBe(pinned.key);
    expect(getSessionByIdentity('8', 'embed-2').node).toBe(pinned.node);
    expect(pinned.node.isConnected).toBe(true);
    expect(pinned.node.getAttribute('src')).toBe(PLAYER);
    pinnedAnchor.remove();
  });

  it('keeps an iframe when another anchor replaces the last one before the turn ends', async () => {
    const session = openSession({ statusId: '8', mediaId: 'embed-3', kind: 'iframe', url: PLAYER });
    const first = document.createElement('div');
    const second = document.createElement('div');
    document.body.append(first, second);
    const gone = registerAnchor({ key: session.key, element: first, prefer: true, releaseMode: () => 'detach' });
    unregisterAnchor(gone);
    registerAnchor({ key: session.key, element: second, prefer: true, releaseMode: () => 'detach' });
    await act(async () => {});

    expect(getSessionByIdentity('8', 'embed-3').node).toBe(session.node);
    expect(session.node.getAttribute('src')).toBe(PLAYER);
    first.remove();
    second.remove();
  });

  it('does not keep an unpinned iframe for every post that scrolls away', async () => {
    const anchors = [];

    for (let index = 0; index < 4; index += 1) {
      const session = openSession({ statusId: `post-${index}`, mediaId: 'embed', kind: 'iframe', url: PLAYER });
      const anchor = document.createElement('div');
      document.body.appendChild(anchor);
      const anchorId = registerAnchor({ key: session.key, element: anchor, prefer: true, releaseMode: () => 'detach' });
      anchors.push({ anchor, anchorId, key: session.key });
    }

    expect(connectedPlayerNodes('iframe')).toHaveLength(4);
    pinSession(anchors[0].key);
    anchors.forEach(({ anchorId }) => unregisterAnchor(anchorId));
    await act(async () => {});

    expect(connectedPlayerNodes('iframe')).toHaveLength(1);
    expect(getPinnedKey()).toBe(anchors[0].key);
    anchors.forEach(({ anchor }) => anchor.remove());
  });

  it('ends a session when the last revealed anchor is concealed and keeps it when another copy remains', () => {
    const session = openSession({ statusId: '3', mediaId: 'embed-1', kind: 'iframe', url: PLAYER });
    const first = document.createElement('div');
    const second = document.createElement('div');
    document.body.append(first, second);
    let secondMode = 'detach';
    const concealed = registerAnchor({ key: session.key, element: first, prefer: true, releaseMode: () => 'end' });
    const other = registerAnchor({ key: session.key, element: second, prefer: false, releaseMode: () => secondMode });

    unregisterAnchor(concealed);
    expect(getSessionByIdentity('3', 'embed-1').node).toBe(session.node);

    secondMode = 'end';
    unregisterAnchor(other);
    expect(getSessionByIdentity('3', 'embed-1')).toBeNull();
    first.remove();
    second.remove();
  });

  it('ends sessions for deletion, content warnings, logout, subscription removal, and access loss', () => {
    openSession({ statusId: '1', mediaId: 'a', kind: 'audio', url: TALK });
    openSession({ statusId: '2', mediaId: 'b', kind: 'video', url: CLIP });
    reduceExternalPlayerAction({ type: 'TIMELINE_DELETE', id: '1', references: ['9'] });
    expect(getSessionByIdentity('1', 'a')).toBeNull();
    expect(getSessionByIdentity('2', 'b')).not.toBeNull();

    reduceExternalPlayerAction({ type: 'STATUS_HIDE', ids: ['2'] });
    expect(getSessionByIdentity('2', 'b')).toBeNull();

    const pinned = openSession({ statusId: '5', mediaId: 'embed-1', kind: 'iframe', url: PLAYER });
    pinSession(pinned.key);
    reduceExternalPlayerAction({ type: 'PICTURE_IN_PICTURE_DEPLOY', statusId: '6', props: { currentTime: 3 } });
    expect(getPinnedKey()).toBeNull();
    expect(getSessionByIdentity('5', 'embed-1')).toBeNull();

    openSession({ statusId: '7', mediaId: 'talk', kind: 'audio', url: TALK });
    applyExternalFeedControl({ ok: true, reason: 'source_deleted', statusId: '7' });
    expect(getSessionByIdentity('7', 'talk')).toBeNull();

    openSession({ statusId: '7', mediaId: 'talk', kind: 'audio', url: TALK });
    openSession({ statusId: '8', mediaId: 'clip', kind: 'video', url: CLIP });
    applyExternalFeedControl({ ok: true, reason: 'subscription_removed' });
    expect(connectedPlayerNodes('audio')).toHaveLength(0);
    expect(connectedPlayerNodes('video')).toHaveLength(0);

    openSession({ statusId: '1', mediaId: 'a', kind: 'audio', url: TALK });
    reduceExternalPlayerAction({ type: 'EXTERNAL_FEEDS_PERMITTED', permitted: false });
    expect(getSessionByIdentity('1', 'a')).toBeNull();

    openSession({ statusId: '1', mediaId: 'a', kind: 'audio', url: TALK });
    endAllExternalPlayers('logout');
    expect(connectedPlayerNodes('audio')).toHaveLength(0);
  });

  it('does not let an attachment float auto-continue remote playback', () => {
    const session = openSession({ statusId: '1', mediaId: 'talk', kind: 'audio', url: TALK });
    const anchor = document.createElement('div');
    document.body.appendChild(anchor);
    const anchorId = registerAnchor({ key: session.key, element: anchor, prefer: true, releaseMode: () => 'detach' });
    session.node.dispatchEvent(new Event('play'));
    setAttachmentFloatActive(true);
    const play = jest.spyOn(session.node, 'play').mockImplementation(() => Promise.resolve());
    unregisterAnchor(anchorId);

    expect(getPinnedKey()).toBeNull();
    expect(play).not.toHaveBeenCalled();
    expect(playbackSnapshot(session.key)).toEqual(expect.objectContaining({ paused: true, userStarted: true }));
    anchor.remove();
  });

  it('removes a remote file after an error and withholds it again until the next open', () => {
    const session = openSession({ statusId: '1', mediaId: 'talk', kind: 'audio', url: TALK });
    session.node.dispatchEvent(new Event('error'));

    expect(getSessionByIdentity('1', 'talk').failed).toBe(true);
    expect(connectedPlayerNodes('audio')).toHaveLength(0);
    expect(document.body.innerHTML).not.toContain(`src="${TALK}"`);

    closeSession(session.key);
    expect(getSessionByIdentity('1', 'talk')).toBeNull();
    expect(document.body.innerHTML).not.toContain(TALK);
  });
});

describe('external player rows', () => {
  it('loads one shared iframe for two copies and restores it without recreating it', async () => {
    const view = render(
      <div>
        <ExternalStatusMedia visible status={embedStatus('10')} />
        <ExternalStatusMedia visible status={embedStatus('10')} />
      </div>,
    );

    expect(connectedPlayerNodes('iframe')).toHaveLength(0);
    fireEvent.click(screen.getAllByRole('button', { name: 'External video 1:01' })[0]);
    await act(async () => {});

    const frame = connectedPlayerNodes('iframe');
    expect(frame).toHaveLength(1);
    expect(frame[0].getAttribute('src')).toBe(PLAYER);
    expect(view.container.innerHTML).not.toContain(PLAYER);
    expect(screen.getByText('This player is open on another copy of this post.')).toBeTruthy();

    fireEvent.click(screen.getAllByRole('button', { name: 'Pop out' })[0]);
    expect(connectedPlayerNodes('iframe')[0]).toBe(frame[0]);
    expect(getPinnedKey()).toBe(externalPlayerKey('10', 'embed-1'));

    fireEvent.click(screen.getAllByRole('button', { name: 'Return to the post' })[0]);
    expect(getPinnedKey()).toBeNull();
    expect(connectedPlayerNodes('iframe')[0]).toBe(frame[0]);

    fireEvent.click(screen.getAllByRole('button', { name: 'Close' })[0]);
    expect(connectedPlayerNodes('iframe')).toHaveLength(0);
    expect(screen.getAllByRole('button', { name: 'External video 1:01' })).toHaveLength(2);
  });

  it('drops the iframe when media is concealed and keeps it when the row unmounts', async () => {
    const view = render(<ExternalStatusMedia visible status={embedStatus('11')} />);
    fireEvent.click(screen.getByRole('button', { name: 'External video 1:01' }));
    expect(connectedPlayerNodes('iframe')[0]).toBeTruthy();

    view.rerender(<ExternalStatusMedia visible={false} sensitive status={embedStatus('11')} />);
    await act(async () => {});
    expect(connectedPlayerNodes('iframe')).toHaveLength(0);

    view.rerender(<ExternalStatusMedia visible status={embedStatus('11')} />);
    fireEvent.click(screen.getByRole('button', { name: 'External video 1:01' }));
    const again = connectedPlayerNodes('iframe')[0];
    view.unmount();
    await act(async () => {});
    expect(again.isConnected).toBe(false);
    expect(connectedPlayerNodes('iframe')).toHaveLength(0);
  });

  it('shows remote controls only after a click and continues playback from the play event', () => {
    const view = render(
      <ExternalStatusMedia
        visible
        status={remoteStatus('12', [
          { id: 'clip', type: 'video', url: CLIP, description: 'Clip' },
          { id: 'talk', type: 'audio', url: TALK, description: 'Talk' },
        ])}
      />,
    );

    expect(view.container.innerHTML).not.toContain(CLIP);
    expect(document.body.innerHTML).not.toContain(CLIP);
    fireEvent.click(screen.getByRole('button', { name: /Talk/ }));

    const audio = connectedPlayerNodes('audio')[0];
    expect(audio.getAttribute('src')).toBe(TALK);
    expect(audio.hasAttribute('autoplay')).toBe(false);
    expect(audio.getAttribute('preload')).toBe('none');
    expect(audio.getAttribute('referrerpolicy')).toBe('no-referrer');
    expect(view.container.innerHTML).not.toContain(CLIP);
    const play = jest.spyOn(audio, 'play').mockImplementation(() => Promise.resolve());
    audio.dispatchEvent(new Event('play'));

    view.unmount();
    expect(play).not.toHaveBeenCalled();
    expect(getPinnedKey()).toBe(externalPlayerKey('12', 'talk'));
    expect(audio.isConnected).toBe(true);
    expect(playbackSnapshot(audio.getAttribute('data-external-player-key'))).toEqual(expect.objectContaining({
      paused: false,
      ended: false,
      userStarted: true,
      pinned: true,
    }));
  });
});
