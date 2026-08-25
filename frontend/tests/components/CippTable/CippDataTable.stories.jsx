import React from 'react'
import { http, HttpResponse } from 'msw'
import { fn, within, expect, userEvent, waitFor } from 'storybook/test'
import { CippDataTable } from '../../../src/components/CippTable/CippDataTable'
import { SettingsProvider } from '../../../src/contexts/settings-context'
import { Delete, Edit, Visibility, Block, CheckCircle } from '@mui/icons-material'
import { getIntuneDeviceActions } from '../../../src/components/CippComponents/CippIntuneDeviceActions'

const generateLargeDataset = (count = 10000) => {
  const firstNames = [
    'Alice', 'Bob', 'Carol', 'Dave', 'Eve',
    'Frank', 'Grace', 'Hank', 'Ivy', 'Jack',
    'Karen', 'Leo', 'Mia', 'Noah', 'Olivia',
    'Paul', 'Quinn', 'Rachel', 'Sam', 'Tina',
  ]
  const lastNames = [
    'Smith', 'Johnson', 'Williams', 'Brown', 'Jones',
    'Garcia', 'Miller', 'Davis', 'Rodriguez', 'Martinez',
    'Anderson', 'Taylor', 'Thomas', 'Moore', 'Jackson',
  ]
  const domains = ['contoso.com', 'fabrikam.com', 'northwind.com', 'adventure-works.com']
  const departments = ['IT', 'Sales', 'Marketing', 'Engineering', 'HR', 'Finance', 'Legal', 'Operations']
  const jobTitles = ['Manager', 'Developer', 'Analyst', 'Director', 'Coordinator', 'Specialist', 'Administrator', 'Engineer']
  const severities = ['High', 'Medium', 'Low', 'Informational']
  const statuses = ['Success', 'Failed', 'In Progress', 'Not Started', 'Warning']
  const riskLevels = ['none', 'low', 'medium', 'high', 'hidden']
  const states = ['enabled', 'disabled', 'enabledForReportingButNotEnforced']
  const delegationStatuses = ['directTenant', 'granularDelegatedAdminPrivileges']
  const licenseGuids = [
    '05e9a617-0261-4cee-bb44-138d3ef5d965',
    '06ebc4ee-1bb5-47dd-8120-11324bc54e06',
    'f30db892-07e9-47e9-837c-80727f46fd3d',
    '4b585984-651b-448a-9e53-3b10f069cf7f',
  ]

  const pick = (arr) => arr[Math.floor(Math.random() * arr.length)]
  const randomDate = (startYear, endYear) => {
    const start = new Date(startYear, 0, 1).getTime()
    const end = new Date(endYear, 11, 31).getTime()
    return new Date(start + Math.random() * (end - start)).toISOString()
  }

  return Array.from({ length: count }, (_, i) => {
    const first = pick(firstNames)
    const last = pick(lastNames)
    const domain = pick(domains)
    const upn = `${first.toLowerCase()}.${last.toLowerCase()}${i}@${domain}`

    return {
      id: `00000000-0000-0000-0000-${String(i).padStart(12, '0')}`,
      displayName: `${first} ${last}`,
      userPrincipalName: upn,
      mail: upn,
      createdDateTime: randomDate(2020, 2025),
      lastSignInDateTime: randomDate(2024, 2026),
      accountEnabled: Math.random() > 0.2,
      proxyAddresses: [
        `SMTP:${upn}`,
        `smtp:${first.toLowerCase()}${i}@${domain}`,
        ...(Math.random() > 0.5 ? [`smtp:alias${i}@${domain}`] : []),
      ],
      assignedLicenses: [
        { skuId: pick(licenseGuids) },
        ...(Math.random() > 0.5 ? [{ skuId: pick(licenseGuids) }] : []),
      ],
      Severity: pick(severities),
      Status: pick(statuses),
      riskLevel: pick(riskLevels),
      state: pick(states),
      info: {
        displayName: `${first} ${last} (Info)`,
      },
      businessPhones: Math.random() > 0.3
        ? [
            `+1-555-${String(Math.floor(Math.random() * 9000) + 1000)}`,
            ...(Math.random() > 0.5
              ? [`+1-555-${String(Math.floor(Math.random() * 9000) + 1000)}`]
              : []),
          ]
        : [],
      delegatedPrivilegeStatus: pick(delegationStatuses),
      jobTitle: pick(jobTitles),
      department: pick(departments),
    }
  })
}

// Rich dataset (500 rows), all formatter fields for thorough coverage
const richDataset = generateLargeDataset(500)


const basicData = [
  {
    displayName: 'Alice Smith',
    mail: 'alice@contoso.com',
    department: 'IT',
    accountEnabled: true,
    createdDateTime: '2024-01-15T10:30:00Z',
  },
  {
    displayName: 'Bob Johnson',
    mail: 'bob@contoso.com',
    department: 'Sales',
    accountEnabled: true,
    createdDateTime: '2024-03-22T14:15:00Z',
  },
  {
    displayName: 'Carol Williams',
    mail: 'carol@contoso.com',
    department: 'HR',
    accountEnabled: false,
    createdDateTime: '2023-11-01T09:00:00Z',
  },
]

export default {
  title: 'Components/CippTable/CippDataTable',
  component: CippDataTable,
  tags: ['autodocs'],
  args: {
    maxHeightOffset: '100px',
  },
  decorators: [
    (Story) => (
      <SettingsProvider>
        <Story />
      </SettingsProvider>
    ),
  ],
}

export const BasicUsage = {
  args: {
    title: 'Basic User List',
    data: basicData,
  },
  play: async ({ canvasElement, step }) => {
    await step('rows render from the data prop', async () => {
      await waitFor(() => {
        expect(canvasElement.textContent).toContain('Alice Smith')
      })
      expect(canvasElement.textContent).toContain('bob@contoso.com')
      expect(canvasElement.textContent).toContain('HR')
    })
  },
}

export const SimpleColumns = {
  args: {
    title: 'Users (Simple Columns)',
    data: richDataset.slice(0, 50),
    simpleColumns: ['displayName', 'mail', 'accountEnabled', 'department'],
  },
}

export const AllFormatters = {
  args: {
    title: 'All Formatters (500 rows)',
    data: richDataset,
    simpleColumns: [
      'displayName',
      'userPrincipalName',
      'createdDateTime',
      'lastSignInDateTime',
      'accountEnabled',
      'proxyAddresses',
      'assignedLicenses',
      'Severity',
      'Status',
      'riskLevel',
      'state',
      'info.displayName',
      'businessPhones',
      'department',
    ],
  },
}

export const LargeDatasetApi = {
  args: {
    title: 'API-Driven (1k rows)',
    api: {
      url: '/api/ListUsers',
      dataKey: 'Results',
    },
    queryKey: 'storybook-ListUsers-1k',
    simpleColumns: [
      'displayName',
      'userPrincipalName',
      'createdDateTime',
      'lastSignInDateTime',
      'accountEnabled',
      'proxyAddresses',
      'assignedLicenses',
      'Severity',
      'Status',
      'riskLevel',
      'state',
      'businessPhones',
      'department',
      'jobTitle',
    ],
  },
}

export const WithActions = {
  args: {
    title: 'Users with Actions',
    data: richDataset.slice(0, 25),
    simpleColumns: ['displayName', 'userPrincipalName', 'accountEnabled', 'Status'],
    actions: [
      {
        label: 'View User',
        icon: <Visibility />,
        noConfirm: true,
        customFunction: fn(),
      },
      {
        label: 'Edit User',
        icon: <Edit />,
        noConfirm: true,
        customFunction: fn(),
      },
      {
        label: 'Block Sign-in',
        icon: <Block />,
        color: 'warning.main',
        noConfirm: true,
        customFunction: fn(),
      },
      {
        label: 'Delete User',
        icon: <Delete />,
        color: 'error.main',
        noConfirm: true,
        customFunction: fn(),
      },
    ],
  },
  play: async ({ canvasElement, args, step }) => {
    const root = within(document.body)

    await step('open the first row action menu', async () => {
      await waitFor(() => {
        const icons = canvasElement.querySelectorAll('[data-testid="MoreHorizIcon"]')
        expect(icons.length).toBeGreaterThan(0)
      })
      const actionButton = canvasElement.querySelectorAll('[data-testid="MoreHorizIcon"]')[0].closest('button')
      await userEvent.click(actionButton)
    })

    await step('menu lists the actions', async () => {
      await waitFor(() => {
        expect(root.getByText('View User')).toBeVisible()
      })
      await expect(root.getByText('Delete User')).toBeVisible()
    })

    await step('View User runs its customFunction', async () => {
      await userEvent.click(root.getByText('View User'))
      await expect(args.actions[0].customFunction).toHaveBeenCalledTimes(1)
    })
  },
}

export const WithOffCanvas = {
  args: {
    title: 'Users with Off Canvas',
    data: richDataset.slice(0, 50),
    simpleColumns: ['displayName', 'userPrincipalName', 'department', 'accountEnabled'],
    offCanvas: {
      title: 'User Details',
      extendedInfoFields: [
        'displayName',
        'userPrincipalName',
        'mail',
        'department',
        'jobTitle',
        'accountEnabled',
        'createdDateTime',
      ],
    },
    offCanvasOnRowClick: true,
  },
}

export const WithActionsAndOffCanvas = {
  args: {
    title: 'Users with Actions + Off Canvas',
    data: richDataset.slice(0, 25),
    simpleColumns: ['displayName', 'userPrincipalName', 'Status', 'accountEnabled'],
    actions: [
      {
        label: 'Edit User',
        icon: <Edit />,
        noConfirm: true,
        customFunction: fn(),
      },
    ],
    offCanvas: {
      title: 'User Details',
      extendedInfoFields: ['displayName', 'userPrincipalName', 'mail', 'department'],
    },
  },
}

export const SimpleMode = {
  args: {
    title: 'Compact Table',
    data: richDataset.slice(0, 15),
    simpleColumns: ['displayName', 'mail', 'department'],
    simple: true,
  },
}

export const NoCard = {
  args: {
    title: 'No Card Wrapper',
    data: basicData,
    noCard: true,
  },
}

export const WithFilters = {
  args: {
    title: 'Filtered Users',
    data: richDataset.slice(0, 200),
    simpleColumns: ['displayName', 'department', 'Status', 'accountEnabled'],
    filters: [
      {
        id: 'department',
        value: 'Engineering',
      },
    ],
  },
  play: async ({ canvasElement, step }) => {
    await step('rows render', async () => {
      await waitFor(() => {
        const rows = canvasElement.querySelectorAll('tbody tr')
        expect(rows.length).toBeGreaterThan(0)
      })
    })

    await step('initialState filter leaves only Engineering rows', async () => {
      await waitFor(() => {
        expect(canvasElement.textContent).toContain('Engineering')
      })
      for (const dept of ['Sales', 'Marketing', 'Finance', 'Legal']) {
        expect(canvasElement.textContent).not.toContain(dept)
      }
    })
  },
}

export const LoadingState = {
  args: {
    title: 'Loading Users...',
    data: [],
    isFetching: true,
    simpleColumns: ['displayName', 'mail', 'department'],
  },
  play: async ({ canvasElement, step }) => {
    await step('isFetching renders skeletons, no row text', async () => {
      await waitFor(() => {
        const skeletons = canvasElement.querySelectorAll('.MuiSkeleton-root')
        expect(skeletons.length).toBeGreaterThan(0)
      })
      expect(canvasElement.textContent).not.toContain('Alice Smith')
    })
  },
}

export const DefaultSorting = {
  args: {
    title: 'Sorted by Created Date',
    data: richDataset.slice(0, 100),
    simpleColumns: ['displayName', 'createdDateTime', 'department', 'Status'],
    defaultSorting: [{ id: 'createdDateTime', desc: true }],
  },
  play: async ({ canvasElement, args, step }) => {
    // dateTimeNullsLast sorts on the raw ISO value -> newest createdDateTime first
    const expected = [...args.data].sort(
      (a, b) => new Date(b.createdDateTime) - new Date(a.createdDateTime)
    )[0]

    await step('newest createdDateTime row sorts first', async () => {
      await waitFor(() => {
        const firstRow = canvasElement.querySelector('tbody tr')
        expect(firstRow).not.toBeNull()
        expect(firstRow.textContent).toContain(expected.displayName)
      })
    })
  },
}

export const WithConditionalActions = {
  args: {
    title: 'Conditional Actions',
    data: richDataset.slice(0, 25),
    simpleColumns: ['displayName', 'accountEnabled', 'Status'],
    actions: [
      {
        label: 'Enable Account',
        icon: <CheckCircle />,
        noConfirm: true,
        customFunction: fn(),
        condition: (row) => row.accountEnabled === false,
      },
      {
        label: 'Block Sign-in',
        icon: <Block />,
        color: 'warning.main',
        noConfirm: true,
        customFunction: fn(),
        condition: (row) => row.accountEnabled === true,
      },
    ],
  },
  play: async ({ canvasElement, args, step }) => {
    const root = within(document.body)

    await step('open the first row action menu', async () => {
      await waitFor(() => {
        const icons = canvasElement.querySelectorAll('[data-testid="MoreHorizIcon"]')
        expect(icons.length).toBeGreaterThan(0)
      })
      const actionButton = canvasElement.querySelectorAll('[data-testid="MoreHorizIcon"]')[0].closest('button')
      await userEvent.click(actionButton)
    })

    await step('failed condition renders the action disabled, not hidden', async () => {
      // no sorting -> first menu button belongs to args.data[0]
      const firstRow = args.data[0]
      const enabledLabel = firstRow.accountEnabled ? 'Block Sign-in' : 'Enable Account'
      const disabledLabel = firstRow.accountEnabled ? 'Enable Account' : 'Block Sign-in'
      await waitFor(() => {
        expect(root.getByRole('menuitem', { name: enabledLabel })).toBeVisible()
      })
      await expect(root.getByRole('menuitem', { name: enabledLabel })).not.toHaveAttribute('aria-disabled')
      await expect(root.getByRole('menuitem', { name: disabledLabel })).toHaveAttribute('aria-disabled', 'true')
    })
  },
}

// edit filters drawer only exists for ListGraphRequest-backed tables (CIPPTableToptoolbar)
export const GraphBackedEditFilters = {
  beforeEach({ msw }) {
    msw.use(
      http.get('/api/ListGraphRequest', () =>
        HttpResponse.json({
          Results: [{ userPrincipalName: 'a@x.com', mail: 'a@x.com' }],
          Metadata: {},
        })
      ),
      http.get('/api/ListGraphExplorerPresets', () => HttpResponse.json({ Results: [] }))
    )
  },
  args: {
    title: 'Graph Backed',
    api: { url: '/api/ListGraphRequest', dataKey: 'Results' },
    simpleColumns: ['userPrincipalName', 'mail'],
  },
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement)
    await step('table loads from ListGraphRequest', async () => {
      // getByText('a@x.com') multi-matches (upn + mail cells, plus exact:false substring-matches row text) -> assert via textContent
      await waitFor(async () => {
        expect(canvasElement.textContent).toContain('a@x.com')
      })
    })

    await step('Filters menu opens the edit-filters drawer', async () => {
      // desktop toolbar's own "Filters" button (ModernButton, plain text, no Tooltip) - exact match avoids catching an MRT-native filter toggle if one is added
      const filterButton = await canvas.findByRole('button', { name: 'Filters' })
      await userEvent.click(filterButton)
      const body = within(canvasElement.ownerDocument.body)
      await userEvent.click(await body.findByRole('menuitem', { name: 'Edit filters' }))
      await waitFor(async () => {
        await expect(body.getByRole('button', { name: 'Apply Filter' })).toBeVisible()
      })
    })
  },
}

// cached report column (membersCsv) wears the subTable header, no nested-table button. MRT renders no header cells in jsdom
export const CachedReportColumns = {
  args: {
    title: 'Groups',
    data: [{ id: 'parent-1', displayName: 'Finance', membersCsv: 'Jane, Bob' }],
    simpleColumns: ['displayName', 'members'],
    subTables: [
      {
        id: 'members',
        header: 'Members',
        label: 'View members',
        cachedColumn: 'membersCsv',
        table: {
          title: 'Members of [displayName]',
          api: { url: '/api/TestRelated', dataKey: 'Results' },
          simpleColumns: ['displayName'],
        },
      },
    ],
  },
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement)

    await step('cached csv column takes the subTable header', async () => {
      await waitFor(() => {
        expect(canvas.getByRole('columnheader', { name: /Members/ })).toBeVisible()
      })
      expect(canvas.queryByRole('columnheader', { name: /csv/i })).toBeNull()
    })

    await step('cell shows the cached value, no nested table button', async () => {
      await expect(canvas.getByText('Jane, Bob')).toBeVisible()
      expect(canvas.queryByRole('button', { name: 'View members' })).toBeNull()
    })
  },
}

// tableRowLinks is opt-in, so the row-link stories seed the preference the way a
// user who enabled it would. SettingsProvider reads localStorage on mount, so
// this has to land before the story renders.
const setRowLinksPreference = (value) => {
  const existing = JSON.parse(window.localStorage.getItem('app.settings') || '{}')
  window.localStorage.setItem(
    'app.settings',
    JSON.stringify({ ...existing, tableRowLinks: value })
  )
}

const enableRowLinks = () => setRowLinksPreference(true)
const disableRowLinks = () => setRowLinksPreference(false)


// The primary identity column links to the record's own page, derived from the
// table's existing "View ..." action. jsdom cannot cover this: MRT virtualizes
// the body and needs a real layout engine to render cells at all.
const rowLinkData = [
  { id: 'u-1', displayName: 'Alice Smith', userPrincipalName: 'alice@contoso.com' },
  { id: 'u-2', displayName: 'Bob Johnson', userPrincipalName: 'bob@contoso.com' },
]

const viewUserAction = {
  label: 'View User',
  link: '/identity/administration/users/user?userId=[id]',
  icon: <Visibility />,
}

export const RowLinkFromActions = {
  beforeEach: enableRowLinks,
  args: {
    title: 'Row Links',
    data: rowLinkData,
    actions: [viewUserAction, { label: 'Delete User', type: 'POST', url: '/api/RemoveUser' }],
    simpleColumns: ['displayName', 'userPrincipalName'],
  },
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement)

    await step('display name links to the user page', async () => {
      const link = await canvas.findByRole('link', { name: 'Alice Smith' })
      await expect(link).toHaveAttribute(
        'href',
        '/identity/administration/users/user?userId=u-1'
      )
    })

    await step('only the primary column links', async () => {
      await expect(canvas.queryByRole('link', { name: 'alice@contoso.com' })).toBeNull()
      await expect(await canvas.findByRole('link', { name: 'Bob Johnson' })).toHaveAttribute(
        'href',
        '/identity/administration/users/user?userId=u-2'
      )
    })
  },
}

export const RowLinkSkippedWhenUnresolvable = {
  beforeEach: enableRowLinks,
  args: {
    title: 'Row Links (missing id)',
    // no id on the row, so the [id] token cannot resolve
    data: [{ displayName: 'Alice Smith', userPrincipalName: 'alice@contoso.com' }],
    actions: [viewUserAction],
    simpleColumns: ['displayName', 'userPrincipalName'],
  },
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement)
    await step('renders plain text rather than a broken [id] URL', async () => {
      await waitFor(() => {
        expect(canvasElement.textContent).toContain('Alice Smith')
      })
      await expect(canvas.queryByRole('link', { name: 'Alice Smith' })).toBeNull()
      expect(canvasElement.textContent).not.toContain('[id]')
    })
  },
}

export const RowLinkOptOut = {
  beforeEach: enableRowLinks,
  args: {
    title: 'Row Links (opted out)',
    data: rowLinkData,
    actions: [viewUserAction],
    simpleColumns: ['displayName', 'userPrincipalName'],
    rowLink: false,
  },
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement)
    await step('no cell links when rowLink is false', async () => {
      await waitFor(() => {
        expect(canvasElement.textContent).toContain('Alice Smith')
      })
      await expect(canvas.queryByRole('link', { name: 'Alice Smith' })).toBeNull()
    })
  },
}

// External portal deep links are excluded by testing the link, not the label,
// so "View in CIPP" still works while "View in Entra" is skipped.
export const RowLinkIgnoresExternalActions = {
  beforeEach: enableRowLinks,
  args: {
    title: 'Row Links (external action)',
    data: rowLinkData,
    actions: [
      {
        label: 'View in Entra',
        link: 'https://entra.microsoft.com/#view/x/[id]',
        external: true,
      },
    ],
    simpleColumns: ['displayName', 'userPrincipalName'],
  },
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement)
    await step('an external-only table links nothing', async () => {
      await waitFor(() => {
        expect(canvasElement.textContent).toContain('Alice Smith')
      })
      await expect(canvas.queryByRole('link', { name: 'Alice Smith' })).toBeNull()
    })
  },
}

// Intune devices cannot be seeded in local dev (managedDevices comes from live
// Graph and needs a real enrolled device), so this story stands in for that
// page by using its actual production action array. It proves deviceName is
// picked as the primary column and links into CIPP rather than to the Intune
// deep link that sits directly after it.
export const RowLinkUsesRealIntuneActions = {
  beforeEach: enableRowLinks,
  args: {
    title: 'Devices (real action definitions)',
    data: [
      { id: 'd-1', deviceName: 'LAPTOP-ALICE', userPrincipalName: 'alice@contoso.com' },
      { id: 'd-2', deviceName: 'LAPTOP-BOB', userPrincipalName: 'bob@contoso.com' },
    ],
    actions: getIntuneDeviceActions({ tenantFilter: 'contoso.com' }),
    simpleColumns: ['deviceName', 'userPrincipalName'],
  },
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement)

    await step('device name links into CIPP, not Intune', async () => {
      const link = await canvas.findByRole('link', { name: 'LAPTOP-ALICE' })
      await expect(link).toHaveAttribute('href', '/endpoint/MEM/devices/device?deviceId=d-1')
    })

    await step('the external Intune action is never used for the cell', async () => {
      const hrefs = [...canvasElement.querySelectorAll('tbody a')].map((a) => a.getAttribute('href'))
      expect(hrefs.every((href) => href.startsWith('/endpoint/MEM/devices/device'))).toBe(true)
      expect(hrefs.some((href) => href.includes('intune.microsoft.com'))).toBe(false)
    })
  },
}

// The standards templates page lists "View Tenant Report" before "Edit Template".
// The report is not the row's own record, so the name must link to the template.
export const RowLinkSkipsTenantReportAction = {
  beforeEach: enableRowLinks,
  args: {
    title: 'Standards Templates (real action order)',
    data: [
      { GUID: 't-1', templateName: 'Baseline Alpha', type: 'standard' },
      { GUID: 't-2', templateName: 'Baseline Beta', type: 'standard' },
    ],
    actions: [
      {
        label: 'View Tenant Report',
        link: '/tenant/manage/applied-standards/?templateId=[GUID]',
        target: '_self',
      },
      {
        label: 'Edit Template',
        link: '/tenant/standards/templates/template?id=[GUID]&type=[type]',
        target: '_self',
      },
    ],
    simpleColumns: ['templateName', 'type'],
  },
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement)
    await step('links to the template, not the applied-standards report', async () => {
      const link = await canvas.findByRole('link', { name: 'Baseline Alpha' })
      await expect(link).toHaveAttribute(
        'href',
        '/tenant/standards/templates/template?id=t-1&type=standard'
      )
    })
  },
}

// tableRowLinks is opt-in: with the preference off (the default) a table that
// would otherwise link renders exactly as it always has.
export const RowLinkDisabledByPreference = {
  beforeEach: disableRowLinks,
  args: {
    title: 'Row Links (preference off)',
    data: rowLinkData,
    actions: [viewUserAction],
    simpleColumns: ['displayName', 'userPrincipalName'],
  },
  play: async ({ canvasElement, step }) => {
    const canvas = within(canvasElement)
    await step('nothing links until the preference is enabled', async () => {
      await waitFor(() => {
        expect(canvasElement.textContent).toContain('Alice Smith')
      })
      await expect(canvas.queryByRole('link', { name: 'Alice Smith' })).toBeNull()
    })
  },
}
