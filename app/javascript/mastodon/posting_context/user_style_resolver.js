import { isExistingPostEdit } from './materialize';

// Pure composition of a saved posting style and the composer's current
// destination. It does not read or write Redux.

const occupiedFields = composer => {
  const occupied = new Set();

  if (composer.get('in_reply_to') || composer.get('quote_from')) {
    ['privacy', 'language', 'spoiler', 'sensitive', 'destination'].forEach(field => occupied.add(field));
  }

  return occupied;
};

const manualFields = composer => {
  const fields = composer.getIn(['userPostingStyle', 'manualFields']);

  return {
    has: field => Boolean(fields && fields.includes && fields.includes(field)),
  };
};

const draftHasContent = composer => {
  const text = String(composer.get('text') || '').trim();
  const media = composer.get('media_attachments');
  const poll = composer.get('poll');

  return text.length > 0 || Boolean(media && media.size > 0) || (poll !== null && poll !== undefined);
};

const desiredLanguage = defaults => {
  if (!defaults || !defaults.has || !defaults.has('language')) {
    return undefined;
  }

  const language = defaults.get('language');

  if (!language || !language.get) {
    return undefined;
  }

  if (language.get('mode') === 'auto') {
    return null;
  }

  if (language.get('mode') === 'explicit') {
    return language.get('code') || '';
  }

  return undefined;
};

const desiredSpoiler = defaults => {
  if (!defaults || !defaults.has || !defaults.has('spoiler')) {
    return undefined;
  }

  const spoiler = defaults.get('spoiler');

  if (!spoiler || !spoiler.get) {
    return undefined;
  }

  if (spoiler.get('enabled') === false) {
    return { enabled: false, text: '' };
  }

  if (spoiler.get('enabled') === true) {
    return { enabled: true, text: spoiler.get('text') || '' };
  }

  return undefined;
};

const styleOwnedFields = composer => {
  const fields = composer.getIn(['userPostingStyle', 'styleOwnedFields']);

  return {
    has: field => Boolean(fields && fields.includes && fields.includes(field)),
  };
};

const hasMedia = composer => {
  const media = composer.get('media_attachments');

  return Boolean(media && media.size > 0);
};

// Account defaults, not the value a previous style happened to leave behind.
// Sensitive follows the composer: the account default applies once media exists.
const baselineFor = (composer, name) => {
  if (name === 'privacy') {
    return composer.get('default_privacy');
  }

  if (name === 'language') {
    return composer.get('default_language');
  }

  if (name === 'spoiler') {
    return { enabled: false, text: '' };
  }

  return hasMedia(composer) && composer.get('default_sensitive') === true;
};

const currentFor = (composer, name) => {
  if (name === 'spoiler') {
    return {
      enabled: composer.get('spoiler') === true,
      text: composer.get('spoiler_text') || '',
    };
  }

  if (name === 'sensitive') {
    return composer.get('sensitive') === true;
  }

  return composer.get(name);
};

const sameValue = (name, left, right) => {
  if (name === 'spoiler') {
    return Boolean(left) && Boolean(right) && left.enabled === right.enabled && left.text === right.text;
  }

  return left === right;
};

const writeField = (fields, name, value) => {
  if (name === 'spoiler') {
    fields.spoiler = value.enabled;
    fields.spoilerText = value.enabled ? value.text : '';
    return;
  }

  fields[name] = value;
};

const explicitFields = style => {
  if (!style) {
    return {
      privacy: undefined,
      language: undefined,
      spoiler: undefined,
      sensitive: undefined,
    };
  }

  const defaults = style.get('defaults');

  return {
    privacy: defaults && defaults.has && defaults.has('visibility') ? defaults.get('visibility') : undefined,
    language: desiredLanguage(defaults),
    spoiler: desiredSpoiler(defaults),
    sensitive: defaults && defaults.has && defaults.has('sensitive') ? defaults.get('sensitive') === true : undefined,
  };
};

// Inherit releases a value the previous style wrote. It leaves account
// defaults, manual edits, and reply or quote values where they are.
const composeFields = (style, composer, manual, occupied) => {
  const explicit = explicitFields(style);
  const owned = styleOwnedFields(composer);
  const fields = {};
  const unapplied = [];
  const ownedFields = [];
  const names = ['privacy', 'language', 'spoiler', 'sensitive'];

  names.forEach(name => {
    const specified = explicit[name] !== undefined;
    const current = currentFor(composer, name);
    let wanted;

    if (specified) {
      wanted = explicit[name];
    } else if (owned.has(name)) {
      wanted = baselineFor(composer, name);
    } else {
      return;
    }

    if (manual.has(name) || occupied.has(name)) {
      if (specified && !sameValue(name, wanted, current)) {
        unapplied.push(name);
      }

      return;
    }

    if (!sameValue(name, wanted, current)) {
      writeField(fields, name, wanted);
    }

    if (specified) {
      ownedFields.push(name);
    }
  });

  // PostStatusService stores sensitive when spoiler text is present, even if
  // the client sent false. The composer must show that final value.
  const resultingSpoilerOn = Object.prototype.hasOwnProperty.call(fields, 'spoiler') ? fields.spoiler === true : composer.get('spoiler') === true;
  let resultingSpoilerText = '';

  if (Object.prototype.hasOwnProperty.call(fields, 'spoiler')) {
    resultingSpoilerText = fields.spoiler ? (fields.spoilerText || '') : '';
  } else if (composer.get('spoiler') === true) {
    resultingSpoilerText = composer.get('spoiler_text') || '';
  }
  const serverForcesSensitive = resultingSpoilerOn && String(resultingSpoilerText).trim() !== '';

  if (serverForcesSensitive && !occupied.has('sensitive')) {
    const resultingSensitive = Object.prototype.hasOwnProperty.call(fields, 'sensitive') ? fields.sensitive === true : composer.get('sensitive') === true;

    if (!resultingSensitive) {
      fields.sensitive = true;
    }

    const unappliedIndex = unapplied.indexOf('sensitive');

    if (unappliedIndex >= 0) {
      unapplied.splice(unappliedIndex, 1);
    }

    const styleSetsWarning = Boolean(explicit.spoiler && explicit.spoiler.enabled === true && String(explicit.spoiler.text || '').trim() !== '');

    if (!manual.has('sensitive') && (styleSetsWarning || explicit.sensitive !== undefined) && !ownedFields.includes('sensitive')) {
      ownedFields.push('sensitive');
    }
  } else if (manual.has('sensitive') && !occupied.has('sensitive')) {
    const stored = composer.getIn(['userPostingStyle', 'manualValues', 'sensitive']);
    const resultingSensitive = Object.prototype.hasOwnProperty.call(fields, 'sensitive') ? fields.sensitive === true : composer.get('sensitive') === true;

    if ((stored === true || stored === false) && stored !== resultingSensitive) {
      fields.sensitive = stored === true;
    }
  }

  return { fields, unapplied, ownedFields };
};

const destinationPlan = (style, composer, occupied) => {
  const source = composer.getIn(['userPostingStyle', 'destinationSource']);
  const accountId = composer.getIn(['userPostingStyle', 'destinationAccountId']);
  const status = composer.getIn(['userPostingStyle', 'destinationStatus']);
  const styleOwned = source === 'style';

  if (!style) {
    return {
      action: styleOwned ? 'clear_style' : 'keep',
      accountId: null,
      hashtag: null,
      changes: styleOwned,
    };
  }

  const kind = style.getIn(['target', 'kind']) || 'none';

  if (occupied.has('destination') && kind !== 'none') {
    return {
      action: 'skip',
      accountId: kind === 'group' ? style.getIn(['target', 'accountId']) : null,
      hashtag: kind === 'hashtag' ? style.getIn(['target', 'hashtag']) : null,
      changes: false,
    };
  }

  if (kind === 'hashtag') {
    return {
      action: 'hashtag',
      accountId: null,
      hashtag: style.getIn(['target', 'hashtag']),
      changes: Boolean(styleOwned && accountId),
    };
  }

  if (kind === 'group') {
    const nextAccountId = style.getIn(['target', 'accountId']);
    const sameAccount = styleOwned && String(accountId) === String(nextAccountId);
    const sameReady = sameAccount && status === 'ready';
    const retryFailure = sameAccount && status === 'failed';

    return {
      action: 'group',
      accountId: nextAccountId,
      hashtag: null,
      changes: !sameReady && !retryFailure,
    };
  }

  return {
    action: styleOwned ? 'clear_style' : 'keep',
    accountId: null,
    hashtag: null,
    changes: styleOwned,
  };
};

const blockedPlan = () => ({
  blocked: true,
  selectedId: null,
  revision: null,
  fields: {},
  ownedFields: [],
  unapplied: [],
  destination: { action: 'keep', accountId: null, hashtag: null, changes: false },
  needsConfirmation: false,
});

export function resolveUserPostingStyle(style, composer) {
  if (!composer || isExistingPostEdit(composer)) {
    return blockedPlan();
  }

  const manual = manualFields(composer);
  const occupied = occupiedFields(composer);
  const { fields, unapplied, ownedFields } = composeFields(style, composer, manual, occupied);
  const destination = destinationPlan(style, composer, occupied);

  if (destination.action === 'skip') {
    unapplied.push('destination');
  }

  const privacyChange = Object.prototype.hasOwnProperty.call(fields, 'privacy') && fields.privacy !== composer.get('privacy');
  const destinationChange = destination.changes && (destination.action === 'group' || destination.action === 'clear_style' || destination.action === 'hashtag');

  return {
    blocked: false,
    selectedId: style ? String(style.get('id')) : null,
    revision: style ? style.get('revision') : null,
    fields,
    ownedFields,
    unapplied,
    destination,
    needsConfirmation: !occupied.has('destination') && draftHasContent(composer) && (privacyChange || destinationChange),
  };
}

export function normalizeUserPostingStyle(raw) {
  const target = raw.target || {};
  const managed = raw.managed || {};
  const hashtags = managed.hashtags || [];

  return {
    id: String(raw.id),
    name: raw.name || '',
    icon: raw.icon || '',
    purpose: raw.purpose || '',
    revision: raw.revision,
    enabled: raw.enabled !== false,
    schemaVersion: raw.schema_version,
    target: {
      kind: target.kind || 'none',
      accountId: target.account_id || null,
      hashtag: target.hashtag || null,
      label: target.label || null,
    },
    defaults: raw.defaults || {},
    managed: {
      hashtags: hashtags.map(tag => ({
        name: tag.name,
        normalizedName: tag.normalized_name,
        enforcement: tag.enforcement || 'advisory',
        ruleId: tag.rule_id || null,
      })),
    },
  };
}
