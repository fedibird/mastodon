/**
 * @jest-environment jsdom
 */

import fs from 'fs';
import path from 'path';
import sass from 'sass';

// JSDOM does not compute flex geometry. Assert the *compiled application
// stylesheet* still targets the actual HotKeys wrapper nested by #785.
// Separately verify actual viewport geometry in a browser.
const stylesheet = fs.readFileSync(
  path.resolve(__dirname, '../../../styles/mastodon/basics.scss'),
  'utf8',
);
const sectionStart = stylesheet.indexOf('// The signed-in WebUI is mounted');
const sectionEnd = stylesheet.indexOf('\n.error-boundary', sectionStart);

if (sectionStart === -1 || sectionEnd === -1) {
  throw new Error('Missing the privacy-portal responsive layout rules');
}

const compiledRules = sass.renderSync({
  data: stylesheet.slice(sectionStart, sectionEnd),
}).css.toString();

const componentsStyles = fs.readFileSync(
  path.resolve(__dirname, '../../../styles/mastodon/components.scss'),
  'utf8',
);
const splitStart = componentsStyles.indexOf('body.app-body.layout-single-column.status-timeline-split {');
const splitEnd = componentsStyles.indexOf('\n.column-header__button.column-header__split-button', splitStart);

if (splitStart === -1 || splitEnd === -1) {
  throw new Error('Missing the split-timeline responsive layout rules');
}

const compiledSplitRules = sass.renderSync({
  data: componentsStyles.slice(splitStart, splitEnd),
}).css.toString();

describe('emoji-mute privacy portal responsive layout contract', () => {
  let style;
  let holder;
  let host;
  let privacyRoot;
  let hotkeys;
  let menuRoot;

  beforeEach(() => {
    document.body.className = 'layout-single-column';
    style = document.createElement('style');
    style.textContent = `${compiledRules}\n${compiledSplitRules}`;
    document.head.appendChild(style);

    holder = document.createElement('div');
    holder.className = 'app-holder';
    host = document.createElement('div');
    privacyRoot = document.createElement('div');
    privacyRoot.className = 'emoji-mutes-privacy-portal';
    privacyRoot.style.display = 'contents';
    hotkeys = document.createElement('div');
    menuRoot = document.createElement('div');
    menuRoot.id = 'emoji-actions-overlay-root';
    privacyRoot.appendChild(hotkeys);
    privacyRoot.appendChild(menuRoot);
    host.appendChild(privacyRoot);
    holder.appendChild(host);
    document.body.appendChild(holder);
  });

  afterEach(() => {
    holder.remove();
    style.remove();
    document.body.className = '';
  });

  it('restores the original full-width flex wrapper for mobile while keeping menu root independent', () => {
    const wrapperStyle = window.getComputedStyle(hotkeys);
    expect(window.getComputedStyle(host).display).toBe('flex');
    expect(wrapperStyle.display).toBe('flex');
    expect(wrapperStyle.width).toBe('100%');
    expect(wrapperStyle.minWidth).toBe('0px');
    expect(wrapperStyle.minHeight).toBe('100vh');
    // The dedicated overlay root must not become a full-width flex item.
    expect(window.getComputedStyle(menuRoot).display).not.toBe('flex');
    expect(window.getComputedStyle(menuRoot).width).not.toBe('100%');
  });

  it('applies the mobile split-timeline height contract through the privacy portal', () => {
    document.body.className = 'app-body layout-single-column status-timeline-split';
    const wrapperStyle = window.getComputedStyle(hotkeys);
    expect(wrapperStyle.display).toBe('flex');
    expect(wrapperStyle.width).toBe('100%');
    expect(wrapperStyle.height).toBe('100%');
    expect(wrapperStyle.maxHeight).toBe('100%');
    expect(wrapperStyle.minHeight).toBe('0px');
  });

  it('keeps the original full-height layout under advanced multi-column mode', () => {
    document.body.className = 'layout-multiple-columns';
    const wrapperStyle = window.getComputedStyle(hotkeys);
    expect(wrapperStyle.display).toBe('flex');
    expect(wrapperStyle.width).toBe('100%');
    expect(wrapperStyle.height).toBe('100%');
  });
});
