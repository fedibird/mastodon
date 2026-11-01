export const GROUP_DIRECTORY_LIMIT = 20;

export const groupDirectoryViewKey = (columnId) => (
  columnId ? `column:${columnId}` : 'route'
);

export const normalizeGroupDirectoryParams = (params = {}) => ({
  order: params.order === 'new' ? 'new' : 'active',
  scope: params.scope === 'local' || params.scope === 'following' ? params.scope : 'all',
  software: typeof params.software === 'string' ? params.software : '',
  q: typeof params.q === 'string' ? params.q : '',
});

// Stable identity for one set of filters. Paging state is stored separately.
export const groupDirectoryFilterKey = (params) => {
  const normalized = normalizeGroupDirectoryParams(params);

  return [normalized.order, normalized.scope, normalized.software, normalized.q].join('\n');
};

export const groupDirectoryApiParams = (params) => {
  const normalized = normalizeGroupDirectoryParams(params);
  const apiParams = {
    order: normalized.order,
    limit: GROUP_DIRECTORY_LIMIT,
  };

  if (normalized.scope !== 'all') {
    apiParams.scope = normalized.scope;
  }

  if (normalized.software) {
    apiParams.software = normalized.software;
  }

  if (normalized.q) {
    apiParams.q = normalized.q;
  }

  return apiParams;
};
