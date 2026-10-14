/**
 * /admin/upload — Upload Wizard host page (Bundle B12).
 *
 * Server component that mounts the client-side <UploadWizard /> component.
 * Auth is enforced by `dashboard/src/middleware.ts` for all /admin/* routes.
 */

import UploadWizard from './wizard';

export const dynamic = 'force-dynamic';

export default function UploadPage() {
  return <UploadWizard />;
}
