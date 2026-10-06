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

function badgeRow(container) {
  return Array.from(container.querySelectorAll('.status__content__hashtag-badge')).map(link => link.textContent);
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

  it('shows the only badge and no more button when there is one hashtag', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one']),
    }));

    expect(badgeLabels()).toEqual(['#one']);
    expect(container.querySelector('.status__content__hashtag-more')).toBeNull();
  });

  it('shows both badges and no more button when there are two hashtags', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one', 'two']),
    }));

    expect(badgeLabels()).toEqual(['#one', '#two']);
    expect(container.querySelector('.status__content__hashtag-more')).toBeNull();
  });

  it('shows every badge and no more button when there are three trailing hashtags', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one', 'two', 'three']),
    }));

    expect(badgeLabels()).toEqual(['#one', '#two', '#three']);
    expect(container.querySelector('.status__content__hashtag-more')).toBeNull();
  });

  it('shows all four badges and no more button when there are four', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one', 'two', 'three', 'four']),
    }));

    expect(badgeLabels()).toEqual(['#one', '#two', '#three', '#four']);
    expect(screen.queryByRole('button', { name: /more/ })).toBeNull();
    expect(container.querySelector('.status__content__hashtag-more')).toBeNull();
  });

  it('shows the first three badges and two remaining hashtags when there are five', () => {
    renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one', 'two', 'three', 'four', 'five']),
    }));

    expect(badgeLabels()).toEqual(['#one', '#two', '#three']);
    expect(screen.getByRole('button', { name: '…and 2 more' })).not.toBeNull();
    expect(screen.queryByRole('link', { name: '#five' })).toBeNull();
  });

  it('expands every badge when five hashtags are collapsed and the more button is clicked', () => {
    const onClick = jest.fn();
    const { container } = renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['one', 'two', 'three', 'four', 'five']),
    }), { onClick });

    fireEvent.click(screen.getByRole('button', { name: '…and 2 more' }));

    expect(onClick).not.toHaveBeenCalled();
    expect(badgeLabels()).toEqual(['#one', '#two', '#three', '#four', '#five']);
    expect(screen.queryByRole('button', { name: '…and 2 more' })).toBeNull();
    expect(container.querySelector('.status__content__hashtag-more')).toBeNull();
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

  it('badges an out-of-band tag and leaves a mid-body hashtag in the text', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: `<p>Simple text ${anchor('hashtag')} continues</p>`,
      tags: [
        { name: 'hashtag', url: 'https://example.com/tags/hashtag' },
        { name: 'test', url: 'https://example.com/tags/test' },
      ],
      account: { id: 'a1', display_name: 'Alice', username: 'alice' },
    }));
    const text = container.querySelector('.status__content__text');
    const badge = screen.getByRole('link', { name: '#test' });

    expect(text.innerHTML).toContain('mention hashtag');
    expect(text.textContent).toBe('Simple text #hashtag continues');
    expect(badgeRow(container)).toEqual(['#test']);
    expect(badge).toHaveAttribute('href', 'https://example.com/tags/test');
    expect(badge).toHaveAttribute('data-menu-hashtag', 'test');
    expect(badge).toHaveAttribute('data-account-id', 'a1');
    expect(badge).toHaveAttribute('data-account-name', 'alice');
    expect(badge).toHaveAttribute('data-status-id', 's1');
  });

  it('does not badge a tag that is still visible in the body', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: `<p>本文 ${anchor('foo')} です</p>`,
      tags: [{ name: 'foo', url: 'https://example.com/tags/foo' }],
    }));

    expect(container.querySelector('.status__content__text').textContent).toBe('本文 #foo です');
    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();
  });

  it('drops a duplicate trailing tag and does not badge it when the body still shows it', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: `<p>本文 ${anchor('foo')} です<br>${anchor('foo')}</p>`,
      tags: [{ name: 'foo', url: 'https://example.com/tags/foo' }],
    }));
    const text = container.querySelector('.status__content__text');

    expect(text.textContent).toBe('本文 #foo です');
    expect(text.querySelectorAll('a.mention.hashtag')).toHaveLength(1);
    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();
  });

  it('shows an out-of-band tag before the trailing tag', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: `<p>${anchor('body')} を含む<br>${anchor('tail')}</p>`,
      tags: [
        { name: 'body', url: 'https://example.com/tags/body' },
        { name: 'tail', url: 'https://example.com/tags/tail' },
        { name: 'hidden', url: 'https://example.com/tags/hidden' },
      ],
    }));
    const text = container.querySelector('.status__content__text');

    expect(text.textContent).toContain('#body');
    expect(text.textContent).not.toContain('#tail');
    expect(badgeRow(container)).toEqual(['#hidden', '#tail']);
  });

  it('keeps a remote trailing hashtag badge when status.tags omits it', () => {
    const misskey = [
      '<p>Hello <small>',
      '  <a href="https://misskey.example/tags/one" rel="nofollow noopener noreferrer" class="mention hashtag" target="_blank">#one</a>',
      '</small></p>',
    ].join('\n');
    const pixelfed = [
      'たぶんナラタケモドキ。<br><br>',
      '<a href="https://fedisnap.com/discover/tags/fedibird?src=hash" class="u-url hashtag mention" rel="nofollow noopener noreferrer" target="_blank">#fedibird</a>',
    ].join('');

    const misskeyView = renderStatus(buildStatus({ contentHtml: misskey, tags: [] }));
    expect(misskeyView.container.querySelector('.status__content__text').textContent).toBe('Hello');
    expect(badgeRow(misskeyView.container)).toEqual(['#one']);
    expect(screen.getByRole('link', { name: '#one' })).toHaveAttribute('href', 'https://misskey.example/tags/one');
    misskeyView.unmount();

    const pixelfedView = renderStatus(buildStatus({ contentHtml: pixelfed, tags: [] }));
    expect(badgeRow(pixelfedView.container)).toEqual(['#fedibird']);
    expect(screen.getByRole('link', { name: '#fedibird' })).toHaveAttribute('href', 'https://fedisnap.com/discover/tags/fedibird?src=hash');
  });

  it('shows one badge when a fullwidth trailing hash is also in status.tags', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: '<p>本文 <a href="https://remote.example/tags/foo" class="mention hashtag" rel="tag">＃foo</a></p>',
      tags: [{ name: 'foo', url: 'https://example.com/tags/foo' }],
    }));

    expect(container.querySelector('.status__content__text').textContent).toBe('本文');
    expect(badgeRow(container)).toEqual(['＃foo']);
    expect(container.querySelector('.status__content__hashtag-badge')).toHaveAttribute('href', 'https://remote.example/tags/foo');
    expect(container.querySelector('.status__content__hashtag-badge')).toHaveAttribute('data-menu-hashtag', 'foo');
  });

  it('shows the mixed-case trailing spelling once when the same tag repeats', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: hashtagParagraph(['foo', 'Foo', 'FOO']),
      tags: [{ name: 'foo', url: 'https://api.example/tags/foo' }],
    }));
    const badge = container.querySelector('.status__content__hashtag-badge');

    expect(badgeRow(container)).toEqual(['#Foo']);
    expect(badge).toHaveAttribute('href', 'https://example.com/tags/Foo');
    expect(badge).toHaveAttribute('data-menu-hashtag', 'Foo');
  });

  it('does not badge a second casing of a hashtag that is already visible', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: `<p>この話は ${anchor('FediBird')} についてです<br>${anchor('fedibird')}</p>`,
      tags: [{ name: 'fedibird', url: 'https://example.com/tags/fedibird' }],
    }));
    const text = container.querySelector('.status__content__text');

    expect(text.textContent).toBe('この話は #FediBird についてです');
    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();
  });

  it('hides an out-of-band badge while a content warning is collapsed', () => {
    const { container } = renderStatus(buildStatus({
      contentHtml: `<p>Body ${anchor('foo')} more</p>`,
      tags: [
        { name: 'foo', url: 'https://example.com/tags/foo' },
        { name: 'secret', url: 'https://example.com/tags/secret' },
      ],
      spoiler_text: 'secret',
      spoilerHtml: 'secret',
    }));

    expect(container.querySelector('.status__content__hashtag-badge')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Show more' }));

    expect(badgeRow(container)).toEqual(['#secret']);
    expect(container.querySelector('.status__content__text').textContent).toContain('#foo');
  });

  it('keeps the source out-of-band badge set in translated and bilingual modes', () => {
    const contentHtml = `<p>Talk ${anchor('foo')} here<br>${anchor('tail')}</p>`;
    const tags = [
      { name: 'foo', url: 'https://example.com/tags/foo' },
      { name: 'tail', url: 'https://example.com/tags/tail' },
      { name: 'hidden', url: 'https://example.com/tags/hidden' },
    ];

    ['translated', 'bilingual'].forEach((translationMode) => {
      const view = renderStatus(buildStatus({
        contentHtml,
        tags,
        translationMode,
        translation: translation(`<p>訳 ${anchor('other')} 文<br>${anchor('tail')}</p>`),
      }));
      const text = view.container.querySelector('.status__content__text');

      expect(view.container.querySelectorAll('.status__content__hashtag-badges')).toHaveLength(1);
      expect(badgeRow(view.container)).toEqual(['#hidden', '#tail']);
      expect(text.textContent).toContain('#other');
      expect(text.textContent).not.toContain('#tail');
      expect(text.textContent.includes('#foo')).toBe(translationMode === 'bilingual');
      expect(view.container.querySelector('.status__content__hashtag-badge[data-menu-hashtag="other"]')).toBeNull();
      view.unmount();
    });
  });

  it('keeps the badge row inside collapsed status content', () => {
    const { container } = renderStatus(buildStatus({ collapsed: true }));
    const badge = container.querySelector('.status__content__hashtag-badge');
    const content = badge.closest('.status__content');

    expect(content.className).toContain('status__content--collapsed');
    expect(container.querySelector('.status__content__read-more-button').closest('.status__content')).toBeNull();
  });
});
