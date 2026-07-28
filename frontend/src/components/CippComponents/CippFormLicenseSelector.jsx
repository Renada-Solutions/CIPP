import { CippFormComponent } from './CippFormComponent'
import { getCippLicenseTranslation } from '../../utils/get-cipp-license-translation'
import { useSettings } from '../../hooks/use-settings'

export const CippFormLicenseSelector = ({
  formControl,
  name,
  label,
  multiple = true,
  select,
  addedField,
  showRefresh = false,
  ...other
}) => {
  const userSettingsDefaults = useSettings()
  return (
    <CippFormComponent
      name={name}
      label={label}
      type="autoComplete"
      formControl={formControl}
      multiple={multiple}
      creatable={false}
      api={{
        addedField: {
          ReservedUnits: 'ReservedUnits',
          ProjectedAvailable: 'ProjectedAvailable',
          ...(addedField ?? {}),
        },
        tenantFilter: userSettingsDefaults.currentTenant ?? undefined,
        url: '/api/ListLicenses',
        labelField: (option) =>
          `${getCippLicenseTranslation([option])} (${option?.availableUnits} available)${
            Number(option?.ReservedUnits) > 0 ? ` · ${option.ReservedUnits} reserved` : ''
          }`,
        descriptionField: (option) =>
          Number(option?.ReservedUnits) > 0
            ? `${option.ReservedUnits} seat(s) reserved by pending scheduled tasks · projected available: ${option.ProjectedAvailable}`
            : undefined,
        valueField: 'skuId',
        queryKey: `ListLicenses-${userSettingsDefaults?.currentTenant ?? undefined}`,
        data: {
          Endpoint: 'subscribedSkus',
          $count: true,
          IncludeExcluded: true,
        },
        showRefresh,
      }}
    />
  )
}
