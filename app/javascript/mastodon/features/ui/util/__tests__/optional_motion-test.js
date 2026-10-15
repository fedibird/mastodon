import PropTypes from 'prop-types';
import React from 'react';
import { act, render } from '@testing-library/react';

const queued = [];

jest.mock('raf', () => {
  const raf = (callback) => {
    const id = queued.length + 1;

    queued.push({ id, callback, cancelled: false });
    return id;
  };

  raf.cancel = (id) => {
    const item = queued[id - 1];

    if (item) {
      item.cancelled = true;
    }
  };

  return raf;
});

import ReducedMotion from '../reduced_motion';
import OptionalMotion from '../optional_motion';
import { applyAcceptedAppearance, resetAppearancePreferences } from 'mastodon/utils/appearance_preferences';

let clock = 0;

const flushMotion = (frames = 1) => {
  for (let index = 0; index < frames; index += 1) {
    clock += 32;
    const time = clock;
    const batch = queued.splice(0, queued.length);

    act(() => {
      batch.forEach(item => {
        if (!item.cancelled) {
          item.callback(time);
        }
      });
    });
  }
};

const motionStyle = () => ({
  x: { stiffness: 210, damping: 20, val: 0 },
  opacity: { stiffness: 400, damping: 35, val: 1 },
  backgroundOpacity: { stiffness: 120, damping: 17, val: 0.8 },
  width: 40,
});

const motionDefault = () => ({
  x: -100,
  opacity: 0,
  backgroundOpacity: 0,
  width: 10,
});

const appearance = (motion) => ({
  version: 1,
  preferences: {
    'user.content_font_size': {
      key: 'user.content_font_size',
      public_value: 15,
      public_valid: true,
    },
    'user.info_font_size': {
      key: 'user.info_font_size',
      public_value: 15,
      public_valid: true,
    },
    'user.reduce_motion': {
      key: 'user.reduce_motion',
      public_value: motion,
      public_valid: true,
    },
  },
});

class Probe extends React.Component {

  static propTypes = {
    x: PropTypes.number,
    opacity: PropTypes.number,
    backgroundOpacity: PropTypes.number,
    width: PropTypes.number,
    frames: PropTypes.array,
    mounts: PropTypes.array,
    unmounts: PropTypes.array,
  };

  componentDidMount () {
    this.props.mounts.push('mount');
  }

  componentWillUnmount () {
    this.props.unmounts.push('unmount');
  }

  render () {
    this.props.frames.push({
      x: this.props.x,
      opacity: this.props.opacity,
      backgroundOpacity: this.props.backgroundOpacity,
      width: this.props.width,
    });

    return <span data-testid='motion-frame' />;
  }

}

const mountMotion = (Component, props, record) => render(
  <Component defaultStyle={props.defaultStyle} style={props.style}>
    {style => (
      <Probe
        x={style.x}
        opacity={style.opacity}
        backgroundOpacity={style.backgroundOpacity}
        width={style.width}
        frames={record.frames}
        mounts={record.mounts}
        unmounts={record.unmounts}
      />
    )}
  </Component>,
);

describe('OptionalMotion compared with ReducedMotion', () => {
  beforeEach(() => {
    queued.splice(0, queued.length);
    clock = performance.now();
    resetAppearancePreferences();
    document.body.className = '';
  });

  afterEach(() => {
    resetAppearancePreferences();
  });

  it('paints the same end state as ReducedMotion when reduced motion is already on', () => {
    const reducedRecord = { frames: [], mounts: [], unmounts: [] };
    const liveRecord = { frames: [], mounts: [], unmounts: [] };
    const reducedStyle = motionStyle();
    const reducedDefault = motionDefault();
    const liveStyle = motionStyle();
    const liveDefault = motionDefault();

    applyAcceptedAppearance(appearance(true));
    mountMotion(ReducedMotion, { style: reducedStyle, defaultStyle: reducedDefault }, reducedRecord);
    mountMotion(OptionalMotion, { style: liveStyle, defaultStyle: liveDefault }, liveRecord);

    const reducedFrame = reducedRecord.frames[0];
    const liveFrame = liveRecord.frames[0];

    expect(reducedFrame).toEqual({ x: 0, opacity: 0, backgroundOpacity: 0, width: 40 });
    expect(liveFrame).toEqual(reducedFrame);
    expect(liveStyle.x).toEqual(motionStyle().x);
    expect(liveDefault.x).toBe(-100);
    expect(reducedStyle.x).toBe(0);
    expect(reducedDefault.x).toBe(0);
    expect(reducedStyle.opacity).toEqual({ stiffness: 400, damping: 35, val: 1 });
    expect(reducedDefault.opacity).toBe(0);
    expect(reducedDefault.backgroundOpacity).toBe(0);
    expect(liveStyle.opacity).toEqual({ stiffness: 400, damping: 35, val: 1 });
    expect(liveStyle.backgroundOpacity).toEqual({ stiffness: 120, damping: 17, val: 0.8 });
    expect(liveStyle.width).toBe(40);
  });

  it('snaps movement to the destination without restarting opacity or unmounting the child', () => {
    const record = { frames: [], mounts: [], unmounts: [] };
    const view = mountMotion(OptionalMotion, { style: motionStyle(), defaultStyle: motionDefault() }, record);

    expect(record.frames[0]).toEqual({ x: -100, opacity: 0, backgroundOpacity: 0, width: 10 });
    expect(record.mounts).toEqual(['mount']);

    flushMotion(2);

    const moving = record.frames[record.frames.length - 1];

    expect(moving.x).toBeGreaterThan(-100);
    expect(moving.x).toBeLessThan(0);
    expect(moving.opacity).toBeGreaterThan(0);
    expect(moving.opacity).toBeLessThan(1);
    expect(moving.width).toBe(40);

    act(() => {
      applyAcceptedAppearance(appearance(true));
    });
    flushMotion(1);

    const reduced = record.frames[record.frames.length - 1];

    expect(reduced.x).toBe(0);
    expect(reduced.width).toBe(40);
    expect(reduced.opacity).toBeGreaterThanOrEqual(moving.opacity);
    expect(reduced.opacity).toBeLessThan(1);
    expect(reduced.backgroundOpacity).toBeGreaterThanOrEqual(moving.backgroundOpacity);
    expect(reduced.backgroundOpacity).toBeLessThan(0.8);
    expect(record.unmounts).toEqual([]);
    expect(record.mounts).toEqual(['mount']);

    act(() => {
      view.rerender(
        <OptionalMotion defaultStyle={motionDefault()} style={motionStyle()}>
          {style => (
            <Probe
              x={style.x}
              opacity={style.opacity}
              backgroundOpacity={style.backgroundOpacity}
              width={style.width}
              frames={record.frames}
              mounts={record.mounts}
              unmounts={record.unmounts}
            />
          )}
        </OptionalMotion>,
      );
    });
    act(() => {
      applyAcceptedAppearance(appearance(false));
    });
    flushMotion(2);

    const restored = record.frames[record.frames.length - 1];

    expect(restored.x).toBe(0);
    expect(restored.x).not.toBe(-100);
    expect(restored.opacity).toBeGreaterThanOrEqual(reduced.opacity);
    expect(record.unmounts).toEqual([]);
    expect(record.mounts).toEqual(['mount']);
  });
});
