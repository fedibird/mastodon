import { composerFileDropBlock } from '../composer_media';
import {
  clearColumnDropHighlight,
  composerIdFromEventTarget,
  composerFileDropAlert,
  composerUploadRejectionMessage,
  dropAlreadyHandled,
  dragFeedback,
  isExternalFileDrag,
  markComposerFileDrop,
  planDocumentFileDrop,
  shouldAcceptGlobalFileDrop,
  syncColumnDropHighlight,
} from '../composer_drop';

describe('composer file drop routing', () => {
  it('reads the composer under the pointer and ignores internal media drags', () => {
    document.body.innerHTML = `
      <div data-composer-id="primary"><div id="primary-target"></div></div>
      <div data-composer-id="portable:tag:1"><div id="tag-target"></div></div>
    `;

    expect(composerIdFromEventTarget(document.getElementById('tag-target'))).toBe('portable:tag:1');
    expect(composerIdFromEventTarget(document.body)).toBeNull();
    expect(isExternalFileDrag({ types: ['Files'] })).toBe(true);
    expect(isExternalFileDrag({ types: ['Files', 'application/x-fedibird-media-reorder'] })).toBe(false);
    expect(isExternalFileDrag({ types: ['text/plain'] })).toBe(false);

    const event = { nativeEvent: {} };
    markComposerFileDrop(event);

    expect(dropAlreadyHandled(event)).toBe(true);
    expect(dropAlreadyHandled(event.nativeEvent)).toBe(true);
  });

  it('lets the composer own an internal drop no matter which handler runs first', () => {
    document.body.innerHTML = `
      <div data-composer-id="portable:list:1"><div id="inside"></div></div>
      <div id="outside"></div>
    `;

    const files = [{ name: 'a.png' }, { name: 'b.png' }, { name: 'c.png' }];
    const uploadsFor = (order) => {
      const event = {
        target: document.getElementById('inside'),
        dataTransfer: { types: ['Files'], files },
        nativeEvent: {},
      };
      const uploads = [];
      const composer = () => {
        if (!isExternalFileDrag(event.dataTransfer)) return;

        markComposerFileDrop(event);
        uploads.push(files);
      };
      const global = () => {
        if (shouldAcceptGlobalFileDrop(event)) uploads.push('global');
      };
      const steps = { composer, global };

      order.forEach(name => steps[name]());

      return uploads;
    };

    expect(uploadsFor(['global', 'composer'])).toEqual([files]);
    expect(uploadsFor(['composer', 'global'])).toEqual([files]);
    expect(shouldAcceptGlobalFileDrop({
      target: document.getElementById('outside'),
      dataTransfer: { types: ['Files'], files },
    })).toBe(true);
    expect(files).toHaveLength(3);
  });

  it('routes timeline drops to the visible portable composer and clears the global overlay', () => {
    document.body.innerHTML = `
      <div class="column" data-drop-composer-id="portable:list-column:a" id="list-column">
        <div class="column-header" id="list-title"></div>
        <div data-composer-id="portable:list-column:a"><div id="list-composer"></div></div>
        <article id="list-status"></article>
        <div class="timeline-split">
          <div class="timeline-split__pane--live"><article id="list-live"></article></div>
          <div class="timeline-split__pane--history"><article id="list-history"></article></div>
        </div>
      </div>
      <div class="column" data-drop-composer-id="portable:hashtag-column:b" id="tag-column">
        <article id="tag-status"></article>
      </div>
      <div class="column" data-drop-composer-id="portable:group-column:c" id="group-column">
        <div id="group-detail"></div>
        <article id="group-status"></article>
      </div>
      <div class="column" id="closed-column"><article id="closed-status"></article></div>
      <div id="outside"></div>
      <div class="upload-area" id="upload-overlay"></div>
    `;

    const files = [{ name: 'a.png' }, { name: 'b.png' }, { name: 'c.png' }];
    const drop = (id, { order = ['global'], primaryCanAccept = true, composerCanAccept } = {}) => {
      const event = {
        target: document.getElementById(id),
        dataTransfer: { types: ['Files'], files },
        nativeEvent: {},
      };
      let overlay = true;
      const uploads = [];
      const composer = () => {
        markComposerFileDrop(event);
        uploads.push({ action: 'composer-owned', files });
      };
      const global = () => {
        const plan = planDocumentFileDrop(event, { primaryCanAccept, composerCanAccept });

        if (plan.clearDragUi) overlay = false;
        if (plan.action === 'upload-composer' || plan.action === 'upload-primary') {
          uploads.push({ action: plan.action, composerId: plan.composerId, files });
        }
        if (plan.action === 'reject') uploads.push({ action: 'reject', composerId: plan.composerId });
      };

      order.forEach(step => (step === 'composer' ? composer() : global()));

      return { overlay, uploads };
    };

    expect(drop('list-status').uploads).toEqual([{
      action: 'upload-composer',
      composerId: 'portable:list-column:a',
      files,
    }]);
    expect(drop('list-status').overlay).toBe(false);
    expect(drop('tag-status').uploads[0].composerId).toBe('portable:hashtag-column:b');
    expect(drop('group-detail').uploads[0].composerId).toBe('portable:group-column:c');
    expect(drop('list-live').uploads[0].composerId).toBe('portable:list-column:a');
    expect(drop('list-history').uploads[0].composerId).toBe('portable:list-column:a');
    expect(drop('list-title').uploads[0].composerId).toBe('portable:list-column:a');
    expect(drop('list-composer', { order: ['global', 'composer'] }).uploads).toEqual([{ action: 'composer-owned', files }]);
    expect(drop('list-composer', { order: ['composer', 'global'] }).uploads).toEqual([{ action: 'composer-owned', files }]);
    expect(drop('list-composer', { order: ['global', 'composer'] }).overlay).toBe(false);
    expect(drop('closed-status').uploads[0].action).toBe('upload-primary');
    expect(drop('outside').uploads[0].action).toBe('upload-primary');
    expect(drop('list-status', { primaryCanAccept: false }).uploads[0].action).toBe('upload-composer');
    expect(drop('list-status', {
      composerCanAccept: () => false,
    }).uploads).toEqual([{ action: 'reject', composerId: 'portable:list-column:a' }]);
    expect(drop('tag-status').uploads).toHaveLength(1);
    expect(drop('tag-status').uploads[0].composerId).not.toBe('portable:list-column:a');

    const reorder = planDocumentFileDrop({
      target: document.getElementById('list-status'),
      dataTransfer: { types: ['Files', 'application/x-fedibird-media-reorder'], files },
    });

    expect(reorder.action).toBe('ignore');
    expect(files).toHaveLength(3);

    syncColumnDropHighlight(document.getElementById('list-status'));
    expect(document.getElementById('list-column').classList.contains('is-file-drop-target')).toBe(true);
    clearColumnDropHighlight();
    expect(document.querySelector('.column.is-file-drop-target')).toBeNull();
    expect(dragFeedback(document.getElementById('list-status'), { types: ['Files'] }, { canUploadPrimary: true }).overlay).toBe(false);
    expect(dragFeedback(document.getElementById('outside'), { types: ['Files'] }, { canUploadPrimary: true }).overlay).toBe(true);
  });

  it('does not offer a successful drop on a portable column that cannot accept files', () => {
    document.body.innerHTML = `
      <div class="column" data-drop-composer-id="portable:list-column:a" id="open-column"><article id="open-status"></article></div>
      <div class="column" data-drop-composer-id="portable:group-column:c" id="blocked-column"><article id="blocked-status"></article></div>
      <div class="upload-area" id="upload-overlay"></div>
    `;
    const files = [{ name: 'a.png' }];
    const drag = { types: ['Files'] };
    const canAccept = composerId => composerId === 'portable:list-column:a';
    const open = dragFeedback(document.getElementById('open-status'), drag, { canUploadPrimary: false, composerCanAccept: canAccept });
    const blocked = dragFeedback(document.getElementById('blocked-status'), drag, { canUploadPrimary: true, composerCanAccept: canAccept });

    expect(open).toEqual({ overlay: false, columnId: 'portable:list-column:a', blocked: false });
    expect(blocked).toEqual({ overlay: false, columnId: null, blocked: true });

    syncColumnDropHighlight(document.getElementById('open-status'));
    syncColumnDropHighlight(document.getElementById('blocked-status'), { blocked: true });

    expect(document.getElementById('open-column').classList.contains('is-file-drop-target')).toBe(false);
    expect(document.getElementById('blocked-column').classList.contains('is-file-drop-target')).toBe(false);
    expect(document.getElementById('blocked-column').classList.contains('is-file-drop-blocked')).toBe(true);

    const event = {
      target: document.getElementById('blocked-status'),
      dataTransfer: { types: ['Files'], files },
      nativeEvent: {},
    };
    const plan = planDocumentFileDrop(event, { primaryCanAccept: true, composerCanAccept: canAccept });
    let overlay = true;
    const uploads = [];

    if (plan.clearDragUi) {
      overlay = false;
      clearColumnDropHighlight();
    }
    if (plan.action === 'upload-composer' || plan.action === 'upload-primary') {
      uploads.push(plan.action);
    }

    expect(plan.action).toBe('reject');
    expect(plan.composerId).toBe('portable:group-column:c');
    expect(uploads).toEqual([]);
    expect(overlay).toBe(false);
    expect(document.querySelector('.column.is-file-drop-target, .column.is-file-drop-blocked')).toBeNull();
    expect(composerUploadRejectionMessage('unauthorized').id).toBe('compose_form.upload_blocked.unauthorized');
    expect(composerUploadRejectionMessage('missing').id).toBe('compose_form.upload_blocked');
    expect(composerUploadRejectionMessage('media').id).toBe('compose_form.upload_blocked.media');
    expect(composerUploadRejectionMessage('something-else').id).toBe('upload_error.identity');
  });

  it('matches drag feedback to attachment limits without guessing an unknown file type', () => {
    document.body.innerHTML = `
      <div class="column" data-drop-composer-id="portable:list:full" id="full-column"><article id="full-status"></article></div>
      <div class="column" data-drop-composer-id="portable:list:open" id="open-column"><article id="open-status"></article></div>
    `;
    const blocks = {
      'portable:list:full': composerFileDropBlock({ mediaCount: 4, maxAttachments: 4 }),
      'portable:list:open': composerFileDropBlock({ existingTypes: ['image'], mediaCount: 1, pending: 1, maxAttachments: 4 }),
    };
    const canAccept = composerId => blocks[composerId] === null;
    const drag = { types: ['Files'] };

    expect(blocks['portable:list:full']).toBe('limit');
    expect(blocks['portable:list:open']).toBeNull();
    expect(composerFileDropBlock({ existingTypes: ['video'], mediaCount: 1, maxAttachments: 4 })).toBe('video');
    expect(composerFileDropBlock({ pendingExclusive: 1, pending: 1, maxAttachments: 4 })).toBe('video');
    expect(composerFileDropBlock({ hasPoll: true, allowPollImage: false, maxAttachments: 4 })).toBe('poll_image');
    expect(dragFeedback(document.getElementById('full-status'), drag, { canUploadPrimary: true, composerCanAccept: canAccept })).toEqual({
      overlay: false,
      columnId: null,
      blocked: true,
    });
    expect(dragFeedback(document.getElementById('open-status'), drag, { canUploadPrimary: false, composerCanAccept: canAccept })).toEqual({
      overlay: false,
      columnId: 'portable:list:open',
      blocked: false,
    });

    const droppedVideo = composerFileDropBlock({
      existingTypes: ['image'],
      mediaCount: 1,
      pending: 1,
      maxAttachments: 4,
      incomingMimeTypes: ['video/mp4'],
    });
    const plan = planDocumentFileDrop({
      target: document.getElementById('open-status'),
      dataTransfer: { types: ['Files'], files: [{ type: 'video/mp4' }] },
    }, {
      primaryCanAccept: true,
      composerCanAccept: () => droppedVideo === null,
    });

    expect(droppedVideo).toBe('video');
    expect(plan.action).toBe('reject');
    expect(plan.action).not.toBe('upload-primary');
    expect(composerFileDropAlert('limit').id).toBe('upload_error.limit');
    expect(composerFileDropAlert('video').id).toBe('upload_error.video_exclusive');
    expect(composerFileDropAlert('poll_image').id).toBe('upload_error.poll');
    expect(composerFileDropAlert('missing').id).toBe('compose_form.upload_blocked');
  });
});
