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
    return null;
  }

  const spoiler = defaults.get('spoiler');

  if (!spoiler || !spoiler.get) {
    return null;
  }

  if (spoiler.get('enabled') === false) {
    return { enabled: false, text: '' };
  }

  if (spoiler.get('enabled') === true) {
    return { enabled: true, text: spoiler.get('text') || '' };
  }

  return null;
};

const assignField = ({ unapplied, manual, occupied, name, wanted, current, write }) => {
  if (wanted === undefined) {
    return;
  }

  if (manual.has(name) || occupied.has(name)) {
    if (wanted !== current) {
      unapplied.push(name);
    }

    return;
  }

  write();
};

const usualFields = (composer, manual, occupied) => {
  const fields = {};

  if (!manual.has('privacy') && !occupied.has('privacy')) {
    fields.privacy = composer.get('default_privacy');
  }

  if (!manual.has('language') && !occupied.has('language')) {
    fields.language = composer.get('default_language');
  }

  if (!manual.has('spoiler') && !occupied.has('spoiler')) {
    fields.spoiler = false;
    fields.spoilerText = '';
  }

  if (!manual.has('sensitive') && !occupied.has('sensitive')) {
    fields.sensitive = false;
  }

  return { fields, unapplied: [] };
};

const styleFields = (style, composer, manual, occupied) => {
  const defaults = style.get('defaults');
  const fields = {};
  const unapplied = [];
  const visibility = defaults && defaults.has && defaults.has('visibility') ? defaults.get('visibility') : undefined;
  const language = desiredLanguage(defaults);
  const spoiler = desiredSpoiler(defaults);
  const sensitive = defaults && defaults.has && defaults.has('sensitive') ? defaults.get('sensitive') === true : undefined;

  assignField({
    unapplied,
    manual,
    occupied,
    name: 'privacy',
    wanted: visibility,
    current: composer.get('privacy'),
    write: () => {
      fields.privacy = visibility;
    },
  });

  assignField({
    unapplied,
    manual,
    occupied,
    name: 'language',
    wanted: language,
    current: composer.get('language'),
    write: () => {
      fields.language = language;
    },
  });

  if (spoiler) {
    const same = composer.get('spoiler') === spoiler.enabled && composer.get('spoiler_text') === spoiler.text;

    if (manual.has('spoiler') || occupied.has('spoiler')) {
      if (!same) {
        unapplied.push('spoiler');
      }
    } else {
      fields.spoiler = spoiler.enabled;
      fields.spoilerText = spoiler.text;
    }
  }

  assignField({
    unapplied,
    manual,
    occupied,
    name: 'sensitive',
    wanted: sensitive,
    current: composer.get('sensitive'),
    write: () => {
      fields.sensitive = sensitive;
    },
  });

  return { fields, unapplied };
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
    const sameReady = styleOwned && String(accountId) === String(nextAccountId) && status === 'ready';

    return {
      action: 'group',
      accountId: nextAccountId,
      hashtag: null,
      changes: !sameReady,
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
  const { fields, unapplied } = style ? styleFields(style, composer, manual, occupied) : usualFields(composer, manual, occupied);
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
