export const MAINTENANCE_PHOTO_BUCKET = "maintenance-photos";

export function maintenancePhotoUrl(reference: string) {
  if (/^https?:\/\//i.test(reference)) return reference;
  return reference;
}
