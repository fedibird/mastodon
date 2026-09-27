import escapeTextContentForBrowser from 'escape-html';
import emojify from '../../features/emoji/emoji';
import { unescapeHTML } from '../../utils/html';
import { expandSpoilers } from '../../initial_state';

const domParser = new DOMParser();

const makeEmojiMap = record => record.emojis.reduce((obj, emoji) => {
  obj[`:${emoji.shortcode}:`] = emoji;
  return obj;
}, {});

export function normalizeAccount(account) {
  account = { ...account };
  const domain = account.acct?.split('@')[1] ?? '';

  const emojiMap = makeEmojiMap(account);
  const displayName = account.display_name.trim().length === 0 ? account.username : account.display_name;

  account.display_name_html = emojify(escapeTextContentForBrowser(displayName), emojiMap, domain);
  account.note_emojified = emojify(account.note, emojiMap, domain);
  account.note_plain = unescapeHTML(account.note);
  account.followed_message_emojified = emojify(account.followed_message, emojiMap, domain);

  if (account.fields) {
    account.fields = account.fields.map(pair => ({
      ...pair,
      name_emojified: emojify(escapeTextContentForBrowser(pair.name), emojiMap, domain),
      value_emojified: emojify(pair.value, emojiMap, domain),
      value_plain: unescapeHTML(pair.value),
    }));
  }

  if (account.moved) {
    account.moved = account.moved.id;
  }

  if (!(account.url.startsWith('http://') || account.url.startsWith('https://'))) {
    account.url = account.uri;
  }

  return account;
}

export function normalizeFilterResult(result) {
  const normalResult = { ...result };

  if (normalResult.filter && typeof normalResult.filter === 'object') {
    normalResult.filter = String(normalResult.filter.id);
  }

  return normalResult;
}

const applyEmojiPresentation = (html) => {
  const flagment = domParser.parseFromString(html, 'text/html').documentElement;

  flagment.querySelectorAll('body>p').forEach(p => {
    let imgCount = 0;
    let scale = true;
    let mix = true;

    function emojiScaleCheck(nodes) {
      for (let i = 0; i < nodes.length; i++) {
        let node = nodes[i];

        if (node.nodeType === Node.ELEMENT_NODE && node.tagName === 'IMG' && node.classList.contains('emojione')) {
          imgCount++;
        } else if (node.nodeType === Node.TEXT_NODE && /[^ \t\u200B\u200C\u3000]/.test(node.textContent)) {
          scale = false;
          mix = false;
        } else if (node.nodeType === Node.ELEMENT_NODE && node.tagName === 'A') {
          scale = false;
        } else if (node.nodeType === Node.ELEMENT_NODE && node.tagName === 'SPAN') {
          emojiScaleCheck(node.childNodes);
        }
      }
    }

    emojiScaleCheck(p.childNodes);

    if (scale && imgCount === 1) {
      p.classList.add('emoji-single');
    } else if (scale && imgCount > 1) {
      p.classList.add('emoji-multi');
    } else if (mix && imgCount > 0) {
      p.classList.add('emoji-mix');
    } else if (imgCount > 0){
      p.classList.add('emoji-other');
    }
  });

  return flagment.innerHTML;
};

const preserveMediaTranslations = (mediaAttachments, normalOldStatus) => {
  const previousMedia = normalOldStatus && normalOldStatus.get('media_attachments');

  return mediaAttachments?.map((media, i) => {
    const item = { ...media, order: i };

    if (previousMedia) {
      const oldItem = previousMedia.find(attachment => attachment.get('id') === item.id);

      if (oldItem && oldItem.get('description') === item.description && oldItem.get('translation')) {
        item.translation = oldItem.get('translation');
      }
    }

    return item;
  });
};

export function normalizeStatus(status, normalOldStatus, domain) {
  const normalStatus   = { ...status };

  if (typeof status.account === 'object') {
    normalStatus.account = status.account.id;
  }

  if (status.reblog && status.reblog.id) {
    normalStatus.reblog = status.reblog.id;
  }

  if (status.poll && status.poll.id) {
    normalStatus.poll = status.poll.id;
  }

  if (status.filtered) {
    normalStatus.filtered = status.filtered.map(normalizeFilterResult);
  }

  // Only calculate these values when status first encountered
  // Otherwise keep the ones already in the reducer
  if (normalOldStatus && normalStatus.updated_at === normalOldStatus.get('updated_at')) {
    normalStatus.search_index = normalOldStatus.get('search_index');
    normalStatus.shortHtml = normalOldStatus.get('shortHtml');
    normalStatus.contentHtml = normalOldStatus.get('contentHtml');
    normalStatus.spoilerHtml = normalOldStatus.get('spoilerHtml');
    normalStatus.spoiler_text = normalOldStatus.get('spoiler_text');
    normalStatus.hidden = normalOldStatus.get('hidden');
    normalStatus.visibility = normalOldStatus.get('visibility');
    normalStatus.media_attachments = normalOldStatus.get('media_attachments');

    if (normalOldStatus.get('translation')) {
      normalStatus.translation = normalOldStatus.get('translation');
    }
  } else {
    // If the status has a CW but no contents, treat the CW as if it were the
    // status' contents, to avoid having a CW toggle with seemingly no effect.
    if (normalStatus.spoiler_text && !normalStatus.content) {
      normalStatus.content = normalStatus.spoiler_text;
      normalStatus.spoiler_text = '';
    }

    const spoilerText   = normalStatus.spoiler_text || '';
    // A CW-only post is shown as body text, but the API content is still empty.
    // Index that displayed text so translation (and screen readers) see it.
    const indexedContent = (!status.content && normalStatus.content) ? normalStatus.content : status.content;
    const searchContent  = ([spoilerText, indexedContent].concat((status.poll && status.poll.options) ? status.poll.options.map(option => option.title) : [])).join('\n\n').replace(/<br\s*\/?>/g, '\n').replace(/<\/p><p>/g, '\n\n');
    const emojiMap       = makeEmojiMap(normalStatus);

    const docContentElem = domParser.parseFromString(searchContent, 'text/html').documentElement;
    if (normalStatus.quote !== null) {
      docContentElem.querySelector('.quote-inline')?.remove();
    }
    docContentElem.querySelector('.reference-link-inline')?.remove();
    docContentElem.querySelector('.original-media-link')?.remove();

    normalStatus.search_index      = docContentElem.textContent;
    normalStatus.shortHtml         = '<p>'+emojify(normalStatus.search_index.substr(0, 150), emojiMap, domain) + (normalStatus.search_index.substr(150) ? '...' : '')+'</p>';
    normalStatus.contentHtml       = applyEmojiPresentation(emojify(normalStatus.content, emojiMap, domain));
    normalStatus.spoilerHtml       = emojify(escapeTextContentForBrowser(spoilerText), emojiMap, domain);
    normalStatus.hidden            = expandSpoilers ? false : spoilerText.length > 0 || normalStatus.sensitive;
    normalStatus.visibility        = normalStatus.visibility_ex ? normalStatus.visibility_ex : normalStatus.visibility;
    normalStatus.quote             = null;
    normalStatus.media_attachments = preserveMediaTranslations(status.media_attachments, normalOldStatus);

    if (normalOldStatus && normalOldStatus.get('content') === status.content && (normalOldStatus.get('spoiler_text') || '') === (status.spoiler_text || '') && normalOldStatus.get('translation')) {
      normalStatus.translation = normalOldStatus.get('translation');
    }

    if (normalStatus.url && !(normalStatus.url.startsWith('http://') || normalStatus.url.startsWith('https://'))) {
      normalStatus.url = null;
    }

    normalStatus.url = normalStatus.url || normalStatus.uri;

    normalStatus.media_attachments.forEach(item => {
      if (item.remote_url && !(item.remote_url.startsWith('http://') || item.remote_url.startsWith('https://')))
        item.remote_url = null;
    });
  }

  return normalStatus;
}

export function normalizeStatusTranslation(translation, status, domain = '') {
  const emojis = status.get('emojis');
  const emojiMap = makeEmojiMap({ emojis: emojis ? emojis.toJS() : [] });
  let content = translation.content;
  let spoilerText = translation.spoiler_text;

  // Fedibird already moves a CW-only spoiler into the status body. The
  // translation API still returns that text as spoiler_text with an empty
  // content, so mirror the same display shape here.
  if (!(status.get('spoiler_text') || '') && spoilerText && !content) {
    content = spoilerText;
    spoilerText = '';
  }

  return {
    detected_source_language: translation.detected_source_language,
    language: translation.language,
    provider: translation.provider,
    contentHtml: applyEmojiPresentation(emojify(content, emojiMap, domain)),
    spoilerHtml: emojify(escapeTextContentForBrowser(spoilerText), emojiMap, domain),
    spoiler_text: spoilerText,
  };
}

export function normalizePoll(poll, normalOldPoll) {
  const normalPoll = { ...poll };
  const emojiMap = makeEmojiMap(normalPoll);

  normalPoll.options = poll.options.map((option, index) => {
    const normalOption = {
      ...option,
      voted: poll.own_votes && poll.own_votes.includes(index),
      title_emojified: emojify(escapeTextContentForBrowser(option.title), emojiMap),
    };

    if (normalOldPoll && normalOldPoll.getIn(['options', index, 'title']) === option.title) {
      const translation = normalOldPoll.getIn(['options', index, 'translation']);

      if (translation) {
        normalOption.translation = translation;
      }
    }

    return normalOption;
  });

  return normalPoll;
}

export function normalizePollOptionTranslation(translation, poll) {
  const emojis = poll && poll.get('emojis');
  const emojiMap = makeEmojiMap({ emojis: emojis ? emojis.toJS() : [] });

  return {
    ...translation,
    titleHtml: emojify(escapeTextContentForBrowser(translation.title), emojiMap),
  };
}

export function normalizeAnnouncement(announcement) {
  const normalAnnouncement = { ...announcement };
  const emojiMap = makeEmojiMap(normalAnnouncement);

  normalAnnouncement.contentHtml = emojify(normalAnnouncement.content, emojiMap);

  return normalAnnouncement;
}

export function normalizeCustomEmojiDetail(emoji) {
  const normalEmoji   = { ...emoji };

  if (typeof emoji.creator === 'object') {
    normalEmoji.creator = creator.creator.id;
  }

  normalEmoji.shortcode_with_domain = `${emoji.shortcode}${emoji.local ? '' : `@${emoji.domain}`}`;
  normalEmoji.aliases = emoji.aliases?.map( alias => alias ? escapeTextContentForBrowser(alias) : null );
  normalEmoji.category = emoji.category ? escapeTextContentForBrowser(emoji.category) : null;
  normalEmoji.org_category = emoji.org_category ? escapeTextContentForBrowser(emoji.org_category) : null;

  return normalEmoji;
}
