/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import PropTypes from 'prop-types';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  disableReactions: false,
  translationPrivateContentAllowed: false,
  translationBarVisibility: 'always',
  translationPreferredMode: 'both',
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
  ],
}));

jest.mock('react-overlays/Overlay', () => {
  return ({ show, children }) => (show ? children({ props: { style: {} }, placement: 'bottom' }) : null);
});

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'ja-JP',
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage;

      if (values) {
        message = message.replace(/\{(\w+),\s*plural,\s*other\s*\{#([^}]*)\}\}/g, (_match, key, suffix) => `${values[key]}${suffix}`);

        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key]);
        });
      }

      return message;
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => intl.formatMessage({ defaultMessage }, values),
  };
});

jest.mock('mastodon/containers/poll_container', () => () => <div className='status__poll-stub' />);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/components/icon', () => () => null);

import StatusContent from '../status_content';

const history = { push: jest.fn() };

class RouterProvider extends React.Component {

  static childContextTypes = {
    router: PropTypes.object,
  };

  getChildContext () {
    return { router: { history } };
  }

  render () {
    return this.props.children;
  }

}

const store = createStore(() => fromJS({
  server: {
    translationLanguages: {
      items: {
        en: ['ja'],
        und: ['ja'],
      },
    },
  },
}));

function anchor(name, href = `https://example.com/tags/${encodeURIComponent(name)}`) {
  return `<a href="${href}" class="mention hashtag" rel="tag">#<span>${name}</span></a>`;
}

function hashtagParagraph(names, lead = 'Hello') {
  return `<p>${lead} ${names.map(name => anchor(name)).join(' ')}</p>`;
}

function badgeLabels() {
  return screen.getAllByRole('link', { name: /^#/ }).map(link => link.textContent);
}

const buildStatus = (overrides = {}) => fromJS({
  id: 's1',
  contentHtml: `<p>Hello ${anchor('one')} ${anchor('two')}</p>`,
  spoilerHtml: '',
  spoiler_text: '',
  search_index: 'Hello',
  language: 'en',
  visibility: 'public',
  mentions: [],
  account: { id: 'a1' },
  ...overrides,
});

const translation = (contentHtml, extras = {}) => ({
  contentHtml,
  spoilerHtml: '',
  language: 'ja',
  detected_source_language: 'en',
  requested_source_language: 'en',
  requested_target_language: 'ja',
  provider: 'DeepL',
  ...extras,
});

const renderStatus = (status, props = {}) => {
  const onClick = props.onClick || jest.fn();

  return {
    onClick,
    ...render(
      <Provider store={store}>
        <RouterProvider>
          <StatusContent status={status} onTranslate={jest.fn()} onClick={onClick} {...props} />
        </RouterProvider>
      </Provider>,
    ),
  };
};

describe('StatusContent trailing hashtag badges', () => {
  beforeEach(() => {
    history.push.mockClear();
  });

  it('moves trailing hashtags out of the original body and into one badge row', () => {
    const { container } = renderStatus(buildStatus());
    const text = container.querySelector('.status__content__text');

    expect(text.textContent).toBe('Hello');
    expect(text.querySelector('a.mention.hashtag')).toBeNull();
    expect(container.querySelectorAll('.status__content__hashtag-badges')).toHaveLength(1);
    expect(screen.getAllByRole('link', { name: /^#/ }).map(link => link.textContent)).toEqual(['#one', '#two']);
    expect(screen.getByRole('link', { name: '#one' })).not.toHaveAttribute('aria-label');
    expect(screen.getByRole('link', { name: '#one' })).toHaveAttribute('href', 'https://example.com/tags/one');
    expect(screen.getByRole('link', { name: '#one' }).className).toContain('status-link');
  });

  it('marks a badge for the hashtag menu and does not open the status or the timeline', () => {
    const onClick = jest.fn();
    renderStatus(buildStatus({
      account: { id: 'a1', display_name: 'Alice', username: 'alice' },
    }), { onClick });
    const badge = screen.getByRole('link', { name: '#one' });

    fireEvent.mouseDown(badge, { button: 0, clientX: 10, clientY: 12 });
    fireEvent.mouseUp(badge, { button: 0, clientX: 12, clientY: 14 });
    fireEvent.click(badge, { button: 0, clientX: 12, clientY: 14 });

    expect(onClick).not.toHaveBeenCalled();
    expect(history.push).not.toHaveBeenCalled();
    expect(badge).toHaveAttribute('data-menu-hashtag', 'one');
    expect(badge).toHaveAttribute('data-account-id', 'a1');
    expect(badge).toHaveAttribute('data-account-name', 'alice');
    expect(badge).toHaveAttribute('data-status-id', 's1');
  });

  it('keeps modified and middle clicks on the anchor', () => {
    renderStatus(buildStatus());
    const badge = screen.getByRole('link', { name: '#two' });

    fireEvent.click(badge, { button: 0, ctrlKey: true });
    fireEvent.click(badge, { button: 0, metaKey: true });
    fireEvent.click(badge, { button: 1 });

    expect(history.push).not.toHaveBeenCalled();
  });

  it('still opens the status when the click is on the body text', () => {
    const onClick = jest.fn();
    const { container } = renderStatus(buildStatus(), { onClick });
    const text = container.querySelector('.status__content__text');

    fireEvent.mouseDown(text, { button: 0, clientX: 4, clientY: 4 });
    fireEvent.mouseUp(text, { button: 0, clientX: 6, clientY: 5 });

    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it('shows one source badge row for a matching translation', () => {
    const { container } = renderStatus(buildStatus({
      translationMode: 'translated',
      translation: translation(`<p>こんにちは ${anchor('one')} ${anchor('two')}</p>`),
    }));
    const text = container.querySelector('.status__content__text');

    expect(text.textContent).toBe('こんにちは');
    expect(text.querySelector('a.mention.hashtag')).toBeNull();
    expect(container.querySelectorAll('.status__content__hashtag-badges')).toHaveLength(1);
    expect(screen.getAllByRole('link', { name: /^#/ }).map(link => link.textContent)).toEqual(['#one', '#two']);
  });

  it('shows one badge row in bilingual mode and removes the run from both sides', () => {
    const { container } = renderStatus(buildStatus({
      translationMode: 'bilingual',
      translation: translation(`<p>こんにちは ${anchor('One')} ${anchor('Two')}</p>`),
    }));
    const text = container.querySelector('.status__content__text');

    expect(container.querySelectorAll('.status__content__hashtag-badges')).toHaveLength(1);
    expect(text.querySelectorAll('a.mention.hashtag')).toHaveLength(0);
    expect(text.textContent).toContain('Hello');
    expect(text.textContent).toContain('こんにちは');
    expect(screen.getAllByRole('link', { name: /^#/ }).map(link => link.textContent)).toEqual(['#one', '#two']);
  });

  it('keeps a mismatched target run inline and still shows the source badges', () => {
    const { container } = renderStatus(buildStatus({
      translationMode: 'translated',
      translation: translation(`<p>こんにちは ${anchor('one')} ${anchor('different')}</p>`),
    }));
    const text = container.querySelector('.status__content__text');

    expect(text.textContent).toContain('#one');
    expect(text.textContent).toContain('#different');
    expect(Array.from(text.querySelectorAll('a.mention.hashtag')).map(link => link.textContent)).toEqual(['#one', '#different']);
    expect(Array.from(container.querySelectorAll('.status__content__hashtag-badge')).map(link => link.textContent)).toEqual(['#one', '#two']);
    expect(container.querySelectorAll('.status__content__hashtag-badges')).toHaveLength(1);
  });

  it('hides badges while a content warning is collapsed and shows them after expanding', () => {
    const { container } = renderStatus(buildStatus({
      spoiler_text: 'secret',
      spoilerHtml: 'secret',
    }));

    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();
    expect(container.querySelector('.status__content__text--visible')).toBeNull();
    expect(container.querySelector('.status__content__text').innerHTML).not.toContain('mention hashtag');

    fireEvent.click(screen.getByRole('button', { name: 'Show more' }));

    expect(screen.getAllByRole('link', { name: /^#/ }).map(link => link.textContent)).toEqual(['#one', '#two']);
    expect(container.querySelector('.status__content__text--visible')).not.toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Show less' }));

    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();
    expect(container.querySelector('.status__content__text--visible')).toBeNull();
  });

  it('shows every badge and no more button when there are three trailing hashtags', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one', 'two', 'three']),
    }));

    expect(badgeLabels()).toEqual(['#one', '#two', '#three']);
    expect(container.querySelector('.status__content__hashtag-more')).toBeNull();
  });

  it('shows the first three badges and one remaining hashtag when there are four', () => {
    renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one', 'two', 'three', 'four']),
    }));
    const more = screen.getByRole('button', { name: '…and 1 more' });

    expect(badgeLabels()).toEqual(['#one', '#two', '#three']);
    expect(screen.queryByRole('link', { name: '#four' })).toBeNull();
    expect(more.tagName).toBe('BUTTON');
    expect(more).toHaveAttribute('type', 'button');
    expect(more.className).toContain('status__content__hashtag-more');
  });

  it('shows a remaining count of four when there are seven trailing hashtags', () => {
    renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one', 'two', 'three', 'four', 'five', 'six', 'seven']),
    }));

    expect(badgeLabels()).toEqual(['#one', '#two', '#three']);
    expect(screen.getByRole('button', { name: '…and 4 more' })).not.toBeNull();
    expect(screen.queryByRole('link', { name: '#four' })).toBeNull();
    expect(screen.queryByRole('link', { name: '#seven' })).toBeNull();
  });

  it('expands every badge from the more button without opening the status', () => {
    const onClick = jest.fn();
    const { container } = renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one', 'two', 'three', 'four', 'five', 'six', 'seven']),
    }), { onClick });
    const more = screen.getByRole('button', { name: '…and 4 more' });

    fireEvent.mouseDown(more, { button: 0, clientX: 10, clientY: 12 });
    fireEvent.mouseUp(more, { button: 0, clientX: 12, clientY: 14 });
    fireEvent.click(more);

    expect(onClick).not.toHaveBeenCalled();
    expect(badgeLabels()).toEqual(['#one', '#two', '#three', '#four', '#five', '#six', '#seven']);
    expect(screen.queryByRole('button', { name: '…and 4 more' })).toBeNull();
    expect(container.querySelector('.status__content__hashtag-more')).toBeNull();
  });

  it('hides badges and the more button while a long content warning is collapsed', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one', 'two', 'three', 'four', 'five', 'six']),
      spoiler_text: 'secret',
      spoilerHtml: 'secret',
    }));

    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();
    expect(container.querySelector('.status__content__hashtag-more')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Show more' }));

    expect(badgeLabels()).toEqual(['#one', '#two', '#three']);
    expect(screen.getByRole('button', { name: '…and 3 more' })).not.toBeNull();
    expect(screen.queryByRole('link', { name: '#six' })).toBeNull();
  });

  it('collapses the single source badge row in translated and bilingual modes', () => {
    const names = ['one', 'two', 'three', 'four', 'five', 'six', 'seven'];

    ['translated', 'bilingual'].forEach((translationMode) => {
      const view = renderStatus(buildStatus({
        contentHtml: hashtagParagraph(names),
        translationMode,
        translation: translation(hashtagParagraph(names, 'こんにちは')),
      }));

      expect(view.container.querySelectorAll('.status__content__hashtag-badges')).toHaveLength(1);
      expect(badgeLabels()).toEqual(['#one', '#two', '#three']);
      expect(screen.getByRole('button', { name: '…and 4 more' })).not.toBeNull();
      expect(view.container.querySelector('.status__content__text').querySelector('a.mention.hashtag')).toBeNull();
      view.unmount();
    });
  });

  it('keeps compatibility links in the body and places badges after the text, before poll and the translation bar', () => {
    const html = [
      '<p>Hello',
      '<span class="quote-inline"><br>QT: <a href="https://example.com/q">https://example.com/q</a></span>',
      '<span class="original-media-link"> <a href="https://example.com/m">[Attached: 5 images]</a></span>',
      '<span class="reference-link-inline"> <a href="https://example.com/r">[Ref.]</a></span>',
      `<br>${anchor('one')} ${anchor('two')}`,
      '</p>',
    ].join('');
    const { container } = renderStatus(buildStatus({
      contentHtml: html,
      poll: 'poll-1',
      in_reply_to_id: 'parent',
      in_reply_to_account_id: 'a1',
    }), { showThread: true });
    const content = container.querySelector('.status__content');
    const text = content.querySelector('.status__content__text');
    const order = Array.from(content.children).map(node => node.getAttribute('class'));

    expect(text.querySelector('.quote-inline')).not.toBeNull();
    expect(text.querySelector('.original-media-link')).not.toBeNull();
    expect(text.querySelector('.reference-link-inline')).not.toBeNull();
    expect(text.querySelector('a.mention.hashtag')).toBeNull();
    expect(order).toEqual([
      expect.stringContaining('status__content__text'),
      'status__content__hashtag-badges',
      'status__poll-stub',
      expect.stringContaining('status__content__read-more-button'),
      expect.stringContaining('status__translation-bar'),
    ]);
    expect(content.querySelector('.status__content__hashtag-badges').parentElement).toBe(content);
  });

  it('keeps the badge row inside collapsed status content', () => {
    const { container } = renderStatus(buildStatus({ collapsed: true }));
    const badge = container.querySelector('.status__content__hashtag-badge');
    const content = badge.closest('.status__content');

    expect(content.className).toContain('status__content--collapsed');
    expect(container.querySelector('.status__content__read-more-button').closest('.status__content')).toBeNull();
  });
});
