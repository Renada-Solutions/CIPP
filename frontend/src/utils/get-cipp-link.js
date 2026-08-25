// Decides whether a table cell should link to the record's own page in CIPP,
// and what that href is. The href is derived from the table's existing actions
// array, so a table that already offers "View User" in its row menu needs no
// extra configuration.
//
// Row/template plumbing is shared with row actions rather than reimplemented:
// getNestedValue and getRowTenant come from resolve-row-templates, so a cell
// link resolves a template exactly the way clicking the matching menu item
// would.
import { getNestedValue, getRowTenant } from './resolve-row-templates'

const TOKEN_PATTERN = /\[([^\]]+)\]/g

// resolveRowTemplates leaves an unresolvable [token] literal, which is right for
// a confirmation prompt but not for an href: navigating to `?userId=[id]` is
// worse than not linking at all. This resolves the same way and additionally
// reports whether every token found a value, so the caller can decline.
// Missing means undefined or null only, matching resolveRowTemplates - a
// legitimate 0 or false still resolves.
export const resolveTemplateStrict = (template, row) => {
  if (typeof template !== 'string') {
    return { text: template, resolved: false }
  }
  let resolved = true
  const text = template.replace(TOKEN_PATTERN, (_, key) => {
    const value = getNestedValue(row, key)
    if (value === undefined || value === null) {
      resolved = false
      return `[${key}]`
    }
    return String(value)
  })
  return { text, resolved }
}

// Columns treated as a record's primary identity, in priority order: the first
// one a table actually displays becomes that table's link. Name fields sort
// above userPrincipalName deliberately, because the Users table shows both and
// the display name is the one people read.
//
// Deliberately absent: Tenant/tenantFilter (render as chips), id/GUID/RowKey
// (opaque), and anything that formats as a status, date or boolean.
export const DEFAULT_PRIMARY_COLUMNS = [
  'displayName',
  'DisplayName',
  'deviceName',
  'templateName',
  'TemplateName',
  'RuleName',
  'PolicyName',
  'Name',
  'name',
  'tenantName',
  'siteName',
  'userPrincipalName',
  'PrimarySmtpAddress',
  'title',
]

// "View X" actions that open an aggregate or report rather than the row's own
// record. Both standards tables list "View Tenant Report" ahead of their
// "Edit Template" action, so without this a template name would link to a
// per-tenant report instead of the template.
const AUTO_LINK_LABEL_DENY = ['view tenant report']

const VIEW_LABEL = /^view\b/i
const EDIT_LABEL = /^edit\b/i

const labelOf = (action) =>
  typeof action?.label === 'string' ? action.label.trim().toLowerCase() : ''

// An action navigates inside CIPP. Testing the link rather than the label is
// what lets "View in CIPP" (app registrations, enterprise apps) through while
// still excluding the "View in Intune"/"View in Entra" portal deep links:
// those are absolute https:// URLs and/or carry external: true.
export const isInternalLinkAction = (action) =>
  typeof action?.link === 'string' &&
  action.link.startsWith('/') &&
  !action.external

// A condition that throws means "skip this action", never "break the cell":
// some conditions walk nested paths that sparse rows do not have.
const passesCondition = (action, row) => {
  if (typeof action?.condition !== 'function') {
    return true
  }
  try {
    return !!action.condition(row)
  } catch {
    return false
  }
}

// Pick the action whose link a cell should point at. An explicit actionLabel
// wins outright; otherwise the first "View ..." action that is not a report,
// then the first "Edit ..." action, because many tables only offer Edit and
// there that edit page is the record page.
export const findRowLinkAction = (actions, row, override) => {
  if (!Array.isArray(actions) || actions.length === 0) {
    return null
  }
  const candidates = actions.filter(
    (action) => isInternalLinkAction(action) && passesCondition(action, row)
  )
  if (candidates.length === 0) {
    return null
  }

  const wanted = override?.actionLabel
  if (typeof wanted === 'string') {
    const target = wanted.trim().toLowerCase()
    return candidates.find((action) => labelOf(action) === target) ?? null
  }

  const view = candidates.find(
    (action) =>
      VIEW_LABEL.test(labelOf(action)) &&
      !AUTO_LINK_LABEL_DENY.includes(labelOf(action))
  )
  if (view) {
    return view
  }
  return candidates.find((action) => EDIT_LABEL.test(labelOf(action))) ?? null
}

// Choose the single column that links, from the columns the table displays.
export const pickPrimaryColumn = (columnIds, override) => {
  if (!Array.isArray(columnIds) || columnIds.length === 0) {
    return null
  }
  const forced = override?.column
  if (typeof forced === 'string') {
    return columnIds.includes(forced) ? forced : null
  }
  if (Array.isArray(forced)) {
    return forced.find((column) => columnIds.includes(column)) ?? null
  }
  return (
    DEFAULT_PRIMARY_COLUMNS.find((column) => columnIds.includes(column)) ?? null
  )
}

// Normalise the rowLink prop into an override object, or null when the table
// has opted out. An absent prop means "auto": deriving from the table's own
// actions is the default behaviour, not something pages opt into.
export const normalizeRowLink = (rowLink) => {
  if (rowLink === false || rowLink === null) {
    return null
  }
  if (rowLink === undefined || rowLink === true) {
    return {}
  }
  if (typeof rowLink === 'string' || Array.isArray(rowLink)) {
    return { column: rowLink }
  }
  if (typeof rowLink === 'object') {
    return rowLink
  }
  return null
}

const HAS_TENANT_PARAM = /[?&]tenant(Filter)?=/i

// A row's tenant is not always a bare domain: scheduled tasks store it
// autocomplete-shaped ({ label, value, type }), so unwrap that before putting
// one in a URL. Anything else yields null and the link is emitted without a
// tenant rather than with a stringified "[object Object]".
const tenantToString = (tenant) => {
  if (typeof tenant === 'string') {
    return tenant
  }
  if (
    tenant &&
    typeof tenant === 'object' &&
    typeof tenant.value === 'string'
  ) {
    return tenant.value
  }
  return null
}

// In All Tenants mode the destination page would otherwise resolve its tenant
// to "AllTenants" and fetch nothing, so carry the row's tenant in the URL.
// getRowTenant is the same helper row actions use to scope themselves, so a
// nested row inherits its parent's tenant here too.
export const appendTenantFilter = (href, row, currentTenant) => {
  if (currentTenant !== 'AllTenants' || HAS_TENANT_PARAM.test(href)) {
    return href
  }
  const tenant = tenantToString(getRowTenant(row, currentTenant))
  if (!tenant || tenant === 'AllTenants') {
    return href
  }
  const separator = href.includes('?') ? '&' : '?'
  return `${href}${separator}tenantFilter=${encodeURIComponent(tenant)}`
}

// The per-cell entry point. Returns an href, or null to render the cell
// exactly as CIPP renders it today. Every bail-out below is a null, so this
// can only ever add a link, never change existing output.
export const getCippRowLink = (row, cellName, context) => {
  if (!context?.enabled || !row || typeof cellName !== 'string') {
    return null
  }
  if (!context.primaryColumn || cellName !== context.primaryColumn) {
    return null
  }

  const override = context.override
  const template =
    typeof override?.href === 'string'
      ? override.href
      : findRowLinkAction(context.actions, row, override)?.link

  if (typeof template !== 'string' || !template.startsWith('/')) {
    return null
  }

  // A half-resolved template would navigate to a literal ?userId=[id], so fall
  // back to plain text instead.
  const { text, resolved } = resolveTemplateStrict(template, row)
  if (!resolved) {
    return null
  }

  return appendTenantFilter(text, row, context.currentTenant)
}
