'use client';

// ---------------------------------------------------------------------------
// ImportPreview (thin shell)
// ---------------------------------------------------------------------------
// BUG-22: DASH-07 refactor. Previously this file was a 1,430-line monolith
// with 22+ useState calls and every UI concern (form, table, overrides,
// modals, results) in a single React component. Any local state change
// triggered a full component re-render — a latency risk at 10x data volume.
//
// The file is now a thin shell that:
//   1. Wraps everything in <ImportPreviewProvider>, which owns ALL state and
//      exposes it via React Context. Sub-components reach in with
//      useImportPreviewContext() — no prop drilling >2 levels.
//   2. Branches between the post-import Results view and the preview UI.
//   3. Composes the four sub-components in the correct visual order:
//        Form header → Overrides → Table → Form footer → Form modals
//
// Pure refactor — zero behaviour changes vs the pre-split component.
// ---------------------------------------------------------------------------

import {
  ImportPreviewProvider,
  useImportPreviewContext,
  type PreviewData,
} from './ImportPreviewContext';
import {
  ImportPreviewFormHeader,
  ImportPreviewFormFooter,
  ImportPreviewFormModals,
} from './ImportPreviewForm';
import ImportPreviewOverrides from './ImportPreviewOverrides';
import ImportPreviewTable from './ImportPreviewTable';
import ImportPreviewResults from './ImportPreviewResults';

export default function ImportPreview({
  data,
  onReset,
}: {
  data: PreviewData;
  onReset: () => void;
}) {
  return (
    <ImportPreviewProvider data={data} onReset={onReset}>
      <ImportPreviewShell />
    </ImportPreviewProvider>
  );
}

// ---------------------------------------------------------------------------
// Shell — branches between Results and the live preview wizard UI
// ---------------------------------------------------------------------------

function ImportPreviewShell() {
  const { importResult } = useImportPreviewContext();

  // Render: Import complete
  if (importResult) {
    return <ImportPreviewResults />;
  }

  // Render: Preview
  return (
    <div className="space-y-5 bg-[#FBF8F3] border-2 border-dashed border-[#D4C9B8] rounded-2xl p-5 relative">
      <ImportPreviewFormHeader />
      <ImportPreviewOverrides />
      <ImportPreviewTable />
      <ImportPreviewFormFooter />
      <ImportPreviewFormModals />
    </div>
  );
}
