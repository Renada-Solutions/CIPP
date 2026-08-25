import {
  appendTenantFilter,
  findRowLinkAction,
  getCippRowLink,
  isInternalLinkAction,
  normalizeRowLink,
  pickPrimaryColumn,
  resolveTemplateStrict,
} from '../../src/utils/get-cipp-link'

describe('resolveTemplateStrict', () => {
  it('fills a single token and reports it resolved', () => {
    const result = resolveTemplateStrict(
      '/identity/administration/users/user?userId=[id]',
      { id: 'abc-123' }
    )
    expect(result.text).toBe('/identity/administration/users/user?userId=abc-123')
    expect(result.resolved).toBe(true)
  })

  it('resolves dot-path tokens', () => {
    const result = resolveTemplateStrict('/x?tid=[customer.tenantId]', {
      customer: { tenantId: 'contoso' },
    })
    expect(result.text).toBe('/x?tid=contoso')
    expect(result.resolved).toBe(true)
  })

  // CippApiDialog relies on the literal being left in place so a mis-typed field
  // name is visible in the confirmation prompt.
  it('leaves a missing token as the literal and reports it unresolved', () => {
    const result = resolveTemplateStrict('/x?userId=[id]', { displayName: 'Jane' })
    expect(result.text).toBe('/x?userId=[id]')
    expect(result.resolved).toBe(false)
  })

  // Matches resolveRowTemplates: only undefined/null count as missing, so a
  // legitimate 0 or false still produces a link rather than silently dropping it.
  it.each([
    ['zero', 0, '/x?v=0'],
    ['false', false, '/x?v=false'],
    ['empty string', '', '/x?v='],
  ])('resolves %s rather than treating it as missing', (_label, value, expected) => {
    const result = resolveTemplateStrict('/x?v=[field]', { field: value })
    expect(result.text).toBe(expected)
    expect(result.resolved).toBe(true)
  })

  it.each([
    ['null', null],
    ['undefined', undefined],
  ])('treats %s as unresolved', (_label, value) => {
    const result = resolveTemplateStrict('/x?v=[field]', { field: value })
    expect(result.text).toBe('/x?v=[field]')
    expect(result.resolved).toBe(false)
  })

  it('returns non-string templates untouched', () => {
    expect(resolveTemplateStrict(undefined, {}).text).toBeUndefined()
    expect(resolveTemplateStrict(undefined, {}).resolved).toBe(false)
  })
})

describe('isInternalLinkAction', () => {
  it('accepts internal paths, including "View in CIPP"', () => {
    expect(
      isInternalLinkAction({
        label: 'View in CIPP',
        link: '/tenant/administration/applications/app-registration?appId=[appId]',
        external: false,
      })
    ).toBe(true)
  })

  it('rejects portal deep links and explicit externals', () => {
    expect(
      isInternalLinkAction({
        label: 'View in Intune',
        link: 'https://intune.microsoft.com/#view/x/[id]',
        external: true,
      })
    ).toBe(false)
    expect(
      isInternalLinkAction({ label: 'View in Entra', link: 'https://entra.microsoft.com/x' })
    ).toBe(false)
    expect(isInternalLinkAction({ label: 'Delete User', type: 'POST' })).toBe(false)
  })
})

describe('findRowLinkAction', () => {
  const viewUser = {
    label: 'View User',
    link: '/identity/administration/users/user?userId=[id]',
  }
  const editUser = {
    label: 'Edit User',
    link: '/identity/administration/users/user/edit?userId=[id]',
  }

  it('prefers a View action over an Edit action', () => {
    expect(findRowLinkAction([editUser, viewUser], {}, {})).toBe(viewUser)
  })

  it('falls back to Edit when no View action exists', () => {
    const editContact = {
      label: 'Edit Contact',
      link: '/email/administration/contacts/edit?id=[Guid]',
    }
    expect(findRowLinkAction([editContact], {}, {})).toBe(editContact)
  })

  it('skips actions whose condition is false and takes the next candidate', () => {
    // alert-configuration: "View Task Details" is gated on the row being a
    // scheduled task, so an Alert row should reach "Edit Alert" instead.
    const actions = [
      {
        label: 'View Task Details',
        link: '/cipp/scheduler/task?id=[RowKey]',
        condition: (row) => row?.EventType === 'Scheduled Task',
      },
      {
        label: 'Edit Alert',
        link: '/tenant/administration/alert-configuration/alert?id=[RowKey]',
      },
    ]
    expect(findRowLinkAction(actions, { EventType: 'Alert' }, {})?.label).toBe('Edit Alert')
    expect(
      findRowLinkAction(actions, { EventType: 'Scheduled Task' }, {})?.label
    ).toBe('View Task Details')
  })

  it('skips a condition that throws rather than propagating it', () => {
    const actions = [
      {
        label: 'View Relationship',
        link: '/tenant/gdap-management/relationships/relationship?id=[id]',
        condition: (row) => row.customer.tenantId,
      },
      viewUser,
    ]
    expect(() => findRowLinkAction(actions, { id: '1' }, {})).not.toThrow()
    expect(findRowLinkAction(actions, { id: '1' }, {})).toBe(viewUser)
  })

  it('ignores report actions that are not the row record', () => {
    // tenant/standards/templates lists "View Tenant Report" before "Edit Template".
    const actions = [
      {
        label: 'View Tenant Report',
        link: '/tenant/manage/applied-standards/?templateId=[GUID]',
      },
      {
        label: 'Edit Template',
        link: '/tenant/standards/templates/template?id=[GUID]&type=[type]',
      },
    ]
    expect(findRowLinkAction(actions, {}, {})?.label).toBe('Edit Template')
  })

  it('lets an explicit actionLabel beat every heuristic', () => {
    const actions = [
      { label: 'View Tenant Report', link: '/tenant/manage/applied-standards/?templateId=[GUID]' },
      { label: 'Edit Template', link: '/tenant/standards/templates/template?id=[GUID]' },
    ]
    expect(findRowLinkAction(actions, {}, { actionLabel: 'View Tenant Report' })?.label).toBe(
      'View Tenant Report'
    )
    expect(findRowLinkAction(actions, {}, { actionLabel: 'No Such Action' })).toBeNull()
  })

  it('returns null when there is nothing to link to', () => {
    expect(findRowLinkAction(undefined, {}, {})).toBeNull()
    expect(findRowLinkAction([], {}, {})).toBeNull()
    expect(findRowLinkAction([{ label: 'Delete', type: 'POST' }], {}, {})).toBeNull()
  })
})

describe('pickPrimaryColumn', () => {
  it('prefers displayName over userPrincipalName when both are shown', () => {
    expect(pickPrimaryColumn(['userPrincipalName', 'displayName', 'mail'], {})).toBe('displayName')
  })

  it('falls through the allowlist to the first visible match', () => {
    expect(pickPrimaryColumn(['accountEnabled', 'userPrincipalName'], {})).toBe(
      'userPrincipalName'
    )
  })

  it('returns null when no allowlisted column is visible', () => {
    expect(pickPrimaryColumn(['accountEnabled', 'createdDateTime'], {})).toBeNull()
    expect(pickPrimaryColumn([], {})).toBeNull()
  })

  it('honours a forced column, but only when the table shows it', () => {
    expect(pickPrimaryColumn(['templateName', 'displayName'], { column: 'templateName' })).toBe(
      'templateName'
    )
    expect(pickPrimaryColumn(['displayName'], { column: 'templateName' })).toBeNull()
    expect(pickPrimaryColumn(['displayName'], { column: ['nope', 'displayName'] })).toBe(
      'displayName'
    )
  })
})

describe('normalizeRowLink', () => {
  it('treats an absent prop as auto and false as opted out', () => {
    expect(normalizeRowLink(undefined)).toEqual({})
    expect(normalizeRowLink(true)).toEqual({})
    expect(normalizeRowLink(false)).toBeNull()
    expect(normalizeRowLink(null)).toBeNull()
  })

  it('accepts a column name, a list, or a full override', () => {
    expect(normalizeRowLink('displayName')).toEqual({ column: 'displayName' })
    expect(normalizeRowLink(['a', 'b'])).toEqual({ column: ['a', 'b'] })
    expect(normalizeRowLink({ column: 'a', actionLabel: 'View User' })).toEqual({
      column: 'a',
      actionLabel: 'View User',
    })
  })
})

describe('appendTenantFilter', () => {
  it('adds the row tenant in All Tenants mode', () => {
    expect(appendTenantFilter('/x?userId=1', { Tenant: 'contoso.com' }, 'AllTenants')).toBe(
      '/x?userId=1&tenantFilter=contoso.com'
    )
    expect(appendTenantFilter('/x', { Tenant: 'contoso.com' }, 'AllTenants')).toBe(
      '/x?tenantFilter=contoso.com'
    )
  })

  it('url-encodes the tenant value', () => {
    expect(appendTenantFilter('/x?a=1', { Tenant: 'a b&c' }, 'AllTenants')).toBe(
      '/x?a=1&tenantFilter=a%20b%26c'
    )
  })

  it('leaves the href alone outside All Tenants mode', () => {
    expect(appendTenantFilter('/x?userId=1', { Tenant: 'contoso.com' }, 'contoso.com')).toBe(
      '/x?userId=1'
    )
  })

  it('does not double up when the template already scopes the tenant', () => {
    expect(
      appendTenantFilter('/x?tenantFilter=fabrikam.com', { Tenant: 'contoso.com' }, 'AllTenants')
    ).toBe('/x?tenantFilter=fabrikam.com')
  })

  it('leaves the href alone when the row carries no tenant', () => {
    expect(appendTenantFilter('/x?userId=1', { id: '1' }, 'AllTenants')).toBe('/x?userId=1')
  })
})

describe('getCippRowLink', () => {
  const actions = [
    { label: 'View User', link: '/identity/administration/users/user?userId=[id]' },
  ]
  const context = {
    enabled: true,
    primaryColumn: 'displayName',
    override: {},
    actions,
    currentTenant: 'contoso.com',
  }

  it('links the primary column', () => {
    expect(getCippRowLink({ id: 'abc' }, 'displayName', context)).toBe(
      '/identity/administration/users/user?userId=abc'
    )
  })

  it('leaves every other column alone', () => {
    expect(getCippRowLink({ id: 'abc' }, 'userPrincipalName', context)).toBeNull()
    expect(getCippRowLink({ id: 'abc' }, 'mail', context)).toBeNull()
  })

  // The whole point of the resolved flag: a row without an id must render as
  // text rather than navigating to a literal ?userId=[id].
  it('returns null when the template cannot be fully resolved', () => {
    expect(getCippRowLink({ displayName: 'Jane' }, 'displayName', context)).toBeNull()
  })

  it('returns null when disabled, rowless, or with no primary column', () => {
    expect(getCippRowLink({ id: 'a' }, 'displayName', { ...context, enabled: false })).toBeNull()
    expect(getCippRowLink(null, 'displayName', context)).toBeNull()
    expect(
      getCippRowLink({ id: 'a' }, 'displayName', { ...context, primaryColumn: null })
    ).toBeNull()
  })

  it('returns null when the table has no internal link action', () => {
    expect(
      getCippRowLink({ id: 'a' }, 'displayName', {
        ...context,
        actions: [{ label: 'View in Entra', link: 'https://entra.microsoft.com/x', external: true }],
      })
    ).toBeNull()
  })

  it('uses an explicit href override without consulting actions', () => {
    expect(
      getCippRowLink({ Guid: 'g1' }, 'displayName', {
        ...context,
        actions: undefined,
        override: { href: '/email/administration/contacts/edit?id=[Guid]' },
      })
    ).toBe('/email/administration/contacts/edit?id=g1')
  })

  it('scopes the link to the row tenant in All Tenants mode', () => {
    expect(
      getCippRowLink({ id: 'abc', Tenant: 'fabrikam.com' }, 'displayName', {
        ...context,
        currentTenant: 'AllTenants',
      })
    ).toBe('/identity/administration/users/user?userId=abc&tenantFilter=fabrikam.com')
  })
})

// getRowTenant walks parent rows, so a nested table's link inherits the tenant
// of the row that opened it - the same rule the row menu uses to scope itself.
describe('appendTenantFilter with nested rows', () => {
  it('falls back to the parent row tenant', () => {
    expect(
      appendTenantFilter('/x?id=1', { id: '1', parent: { Tenant: 'contoso.com' } }, 'AllTenants')
    ).toBe('/x?id=1&tenantFilter=contoso.com')
  })

  it('prefers the row tenant over the parent tenant', () => {
    expect(
      appendTenantFilter(
        '/x?id=1',
        { id: '1', Tenant: 'fabrikam.com', parent: { Tenant: 'contoso.com' } },
        'AllTenants'
      )
    ).toBe('/x?id=1&tenantFilter=fabrikam.com')
  })
})

// Scheduled tasks store Tenant autocomplete-shaped, and getRowTenant returns it
// as-is, so without unwrapping the href gained a literal "[object Object]".
describe('appendTenantFilter with non-string tenants', () => {
  it('unwraps an autocomplete-shaped tenant', () => {
    expect(
      appendTenantFilter(
        '/cipp/scheduler/task?id=1',
        { Tenant: { label: 'trncn.onmicrosoft.com', value: 'trncn.onmicrosoft.com', type: 'Tenant' } },
        'AllTenants'
      )
    ).toBe('/cipp/scheduler/task?id=1&tenantFilter=trncn.onmicrosoft.com')
  })

  it('never emits a stringified object', () => {
    const href = appendTenantFilter('/x?id=1', { Tenant: { nope: true } }, 'AllTenants')
    expect(href).toBe('/x?id=1')
    expect(href).not.toContain('object')
  })
})
