import { act, render } from '@testing-library/react';
import PropTypes from 'prop-types';
import React from 'react';

import { applyAcceptedAppearance, acceptedAppearance, reduceMotionNow, resetAppearancePreferences, subscribeReduceMotion } from '../appearance_preferences';
import OptionalMotion, { stylesForMotion } from '../../features/ui/util/optional_motion';

const entry = (key, publicValue, options = {}) => ({
  key,
  state: 'set',
  configured: Object.prototype.hasOwnProperty.call(options, 'configured') ? options.configured : publicValue,
  effective: Object.prototype.hasOwnProperty.call(options, 'effective') ? options.effective : publicValue,
  public_value: publicValue,
  public_valid: options.valid !== false,
  validation_errors: [],
});

const appearanceDocument = (content, info, motion, options = {}) => ({
  version: 1,
  preferences: {
    'user.content_font_size': entry('user.content_font_size', content, { valid: options.contentValid, configured: options.contentConfigured }),
    'user.info_font_size': entry('user.info_font_size', info, { valid: options.infoValid, configured: options.infoConfigured }),
    'user.reduce_motion': entry('user.reduce_motion', motion, { valid: options.motionValid, configured: options.motionConfigured }),
  },
});

describe('accepted appearance', () => {
  beforeEach(() => {
    resetAppearancePreferences();
    document.documentElement.style.removeProperty('--content-font-size');
    document.documentElement.style.removeProperty('--info-font-size');
    document.documentElement.style.removeProperty('--emoji-scale');
    document.body.className = 'app-body theme-mastodon system-font';
  });

  afterEach(() => {
    resetAppearancePreferences();
  });

  it('applies valid public font sizes and motion without touching other inline styles or body classes', () => {
    const scroller = document.createElement('div');
    scroller.scrollTop = 80;
    document.body.appendChild(scroller);
    document.documentElement.style.setProperty('--emoji-scale', '1');

    const applied = applyAcceptedAppearance(appearanceDocument(18, 12, true));

    expect(applied).toEqual({ contentFontSize: 18, infoFontSize: 12, reduceMotion: true });
    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('18px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('12px');
    expect(document.documentElement.style.getPropertyValue('--emoji-scale')).toBe('1');
    expect(Array.from(document.body.classList)).toEqual(['app-body', 'theme-mastodon', 'system-font', 'reduce-motion']);
    expect(document.body.classList.contains('no-reduce-motion')).toBe(false);
    expect(scroller.scrollTop).toBe(80);
    expect(reduceMotionNow(false)).toBe(true);
    scroller.remove();
  });

  it('leaves the current presentation alone for an invalid, missing, or absent document', () => {
    applyAcceptedAppearance(appearanceDocument(16, 14, false));

    const invalid = appearanceDocument('18', 14, 'yes', {
      contentValid: false,
      contentConfigured: '18',
      motionValid: false,
      motionConfigured: 'yes',
    });
    invalid.preferences['user.info_font_size'] = {
      key: 'user.info_font_size',
      state: 'set',
      configured: 19,
      effective: 19,
      public_value: null,
      public_valid: false,
      validation_errors: [],
    };

    expect(acceptedAppearance(invalid)).toEqual({
      contentFontSize: undefined,
      infoFontSize: undefined,
      reduceMotion: undefined,
    });
    expect(applyAcceptedAppearance(invalid)).toEqual({
      contentFontSize: undefined,
      infoFontSize: undefined,
      reduceMotion: undefined,
    });
    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('16px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('14px');
    expect(document.body.classList.contains('no-reduce-motion')).toBe(true);
    expect(reduceMotionNow(true)).toBe(false);

    expect(applyAcceptedAppearance(null)).toBe(null);
    expect(applyAcceptedAppearance({ version: 1 })).toEqual({
      contentFontSize: undefined,
      infoFontSize: undefined,
      reduceMotion: undefined,
    });
    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('16px');
  });

  it('applies one valid key when the others are invalid and ignores configured values', () => {
    applyAcceptedAppearance(appearanceDocument(15, 15, false));
    applyAcceptedAppearance(appearanceDocument(18, 'nope', false, {
      infoValid: false,
      infoConfigured: 20,
      contentConfigured: 11,
    }));

    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('18px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('15px');
    expect(document.body.classList.contains('no-reduce-motion')).toBe(true);
  });

  it('switches motion off without notifying after the value is already applied', () => {
    const listener = jest.fn();
    const unsubscribe = subscribeReduceMotion(listener);

    applyAcceptedAppearance(appearanceDocument(15, 15, true));
    applyAcceptedAppearance(appearanceDocument(15, 15, true));
    expect(listener).toHaveBeenCalledTimes(1);

    applyAcceptedAppearance(appearanceDocument(15, 15, false));
    expect(document.body.classList.contains('reduce-motion')).toBe(false);
    expect(document.body.classList.contains('no-reduce-motion')).toBe(true);
    expect(listener).toHaveBeenCalledTimes(2);

    unsubscribe();
    applyAcceptedAppearance(appearanceDocument(15, 15, true));
    expect(listener).toHaveBeenCalledTimes(2);
    expect(reduceMotionNow(false)).toBe(true);
  });

  it('keeps opacity springs and flattens movement when motion is reduced', () => {
    const style = {
      opacity: { stiffness: 400, damping: 35, val: 1 },
      x: { stiffness: 210, damping: 20, val: 0 },
    };
    const defaultStyle = { opacity: 0, x: -100 };
    const reduced = stylesForMotion(style, defaultStyle, true);

    expect(reduced.style.opacity).toBe(style.opacity);
    expect(reduced.style.x).toBe(0);
    expect(reduced.defaultStyle.x).toBe(0);
    expect(reduced.defaultStyle.opacity).toBe(0);
    expect(style.x).toEqual({ stiffness: 210, damping: 20, val: 0 });
    expect(stylesForMotion(style, defaultStyle, false)).toEqual({ style, defaultStyle });
  });

  it('changes reduced motion without unmounting the animated child', () => {
    const mounts = [];
    const unmounts = [];

    class Marker extends React.Component {

      static propTypes = {
        x: PropTypes.number,
      };

      componentDidMount () {
        mounts.push('mount');
      }

      componentWillUnmount () {
        unmounts.push('unmount');
      }

      render () {
        return <span data-testid='motion-child'>{this.props.x}</span>;
      }

    }

    render(
      <OptionalMotion defaultStyle={{ x: -100 }} style={{ x: { stiffness: 210, damping: 20, val: 0 } }}>
        {({ x }) => <Marker x={x} />}
      </OptionalMotion>,
    );

    expect(mounts).toEqual(['mount']);

    act(() => {
      applyAcceptedAppearance(appearanceDocument(15, 15, true));
    });

    expect(unmounts).toEqual([]);
    expect(mounts).toEqual(['mount']);
    expect(document.body.classList.contains('reduce-motion')).toBe(true);
  });
});
