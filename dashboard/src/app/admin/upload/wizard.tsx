'use client';

/**
 * Upload Wizard component.
 *
 * Drives the per-channel upload flow:
 *   1. Channel pick (DWS / ALM / Direct / ILG / Y&R)
 *   2. File pick (.zip + .xlsx for DWS; .zip + .txt for ALM; .csv for Direct)
 *   3. Required-field toggle preview (read from
 *      /api/admin/required-fields)
 *   4. Preview-then-confirm flow via existing /api/upload/preview +
 *      /api/upload/confirm endpoints.
 */

import { useEffect, useState } from 'react';

type Channel = 'dws' | 'alm' | 'direct' | 'ilg' | 'ynr';

interface RequiredFields {
  channel: Channel;
  require_customer: boolean;
  require_sku: boolean;
  require_cases: boolean;
  require_rep: boolean;
  require_date: boolean;
}

const CHANNEL_LABEL: Record<Channel, string> = {
  dws: 'DWS (consignment, .zip / .xlsx)',
  alm: 'ALM (wholesale EDI, .zip / .txt)',
  direct: 'Direct / Vinsight Sales Detail (.csv, 28 cols)',
  ilg: 'ILG (legacy, .csv)',
  ynr: "Young & Rashleigh (.zip / .csv)",
};

const ACCEPT_BY_CHANNEL: Record<Channel, string> = {
  dws: '.zip,.xlsx',
  alm: '.zip,.txt,.edi',
  direct: '.csv',
  ilg: '.csv',
  ynr: '.zip,.csv',
};

// Cosmetic VIEW_ONLY demo flag — hides the upload actions (Preview / Confirm)
// so the read-only mirror shows no dead write buttons. Real enforcement is the
// middleware 403 (and /admin is blocked entirely). Unset on the live editor
// => the wizard works as before.
const VIEW_ONLY = process.env.NEXT_PUBLIC_VIEW_ONLY === 'true';

export default function UploadWizard() {
  const [channel, setChannel] = useState<Channel>('dws');
  const [file, setFile] = useState<File | null>(null);
  const [previewState, setPreviewState] = useState<
    'idle' | 'previewing' | 'confirming' | 'done' | 'error'
  >('idle');
  const [previewResult, setPreviewResult] = useState<unknown>(null);
  const [error, setError] = useState<string>('');
  const [requiredFields, setRequiredFields] = useState<RequiredFields | null>(null);

  // Load channel-specific required fields
  useEffect(() => {
    let cancelled = false;
    fetch(`/api/admin/required-fields?channel=${channel}`)
      .then((r) => r.json())
      .then((j) => {
        if (!cancelled && j?.ok && j.config) setRequiredFields(j.config);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [channel]);

  async function onPreview() {
    if (!file) {
      setError('Pick a file first.');
      return;
    }
    setPreviewState('previewing');
    setError('');
    setPreviewResult(null);
    try {
      const fd = new FormData();
      fd.append('channel', channel);
      fd.append('file', file);
      const r = await fetch('/api/upload/preview', { method: 'POST', body: fd });
      const j = await r.json();
      if (!r.ok || !j.success) throw new Error(j.error || 'Preview failed');
      setPreviewResult(j);
      setPreviewState('idle');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error');
      setPreviewState('error');
    }
  }

  async function onConfirm() {
    if (!file) return;
    setPreviewState('confirming');
    setError('');
    try {
      const fd = new FormData();
      fd.append('channel', channel);
      fd.append('file', file);
      const r = await fetch('/api/upload', { method: 'POST', body: fd });
      const j = await r.json();
      if (!r.ok || !j.success) throw new Error(j.error || 'Upload failed');
      setPreviewState('done');
      setPreviewResult(j);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error');
      setPreviewState('error');
    }
  }

  return (
    <section className="upload-wizard">
      <h1>Data Upload Wizard</h1>

      <fieldset>
        <legend>1. Channel</legend>
        {(Object.keys(CHANNEL_LABEL) as Channel[]).map((c) => (
          <label key={c} style={{ display: 'block', margin: '4px 0' }}>
            <input
              type="radio"
              name="channel"
              value={c}
              checked={channel === c}
              onChange={() => setChannel(c)}
            />{' '}
            {CHANNEL_LABEL[c]}
          </label>
        ))}
      </fieldset>

      {requiredFields && (
        <fieldset>
          <legend>Required fields for {channel.toUpperCase()}</legend>
          <ul>
            <li>
              Customer: <strong>{requiredFields.require_customer ? 'required' : 'optional'}</strong>
            </li>
            <li>
              SKU: <strong>{requiredFields.require_sku ? 'required' : 'optional'}</strong>
            </li>
            <li>
              Cases / qty: <strong>{requiredFields.require_cases ? 'required' : 'optional'}</strong>
            </li>
            <li>
              Rep: <strong>{requiredFields.require_rep ? 'required' : 'optional'}</strong>
            </li>
            <li>
              Sale date: <strong>{requiredFields.require_date ? 'required' : 'optional'}</strong>
            </li>
          </ul>
          <p style={{ fontSize: 12, color: '#666' }}>
            Defaults are pre-set. Adjust via the admin API if needed.
          </p>
        </fieldset>
      )}

      <fieldset>
        <legend>2. File</legend>
        <input
          type="file"
          accept={ACCEPT_BY_CHANNEL[channel]}
          onChange={(e) => setFile(e.target.files?.[0] ?? null)}
        />
        {file && (
          <p>
            Selected: <code>{file.name}</code> ({Math.round(file.size / 1024)} KB)
          </p>
        )}
      </fieldset>

      {!VIEW_ONLY && (
        <fieldset>
          <legend>3. Action</legend>
          <button onClick={onPreview} disabled={!file || previewState === 'previewing'}>
            Preview (dry-run)
          </button>{' '}
          <button
            onClick={onConfirm}
            disabled={!file || previewState === 'confirming' || !previewResult}
          >
            Confirm import
          </button>
        </fieldset>
      )}
      {VIEW_ONLY && (
        <p style={{ fontSize: 12, color: '#666' }}>
          This is a read-only view. Uploading is disabled in this demo.
        </p>
      )}

      {error && (
        <div style={{ color: 'crimson' }}>
          <strong>Error:</strong> {error}
        </div>
      )}
      {previewState === 'done' && previewResult ? (
        <div style={{ background: '#eef', padding: 8 }}>
          <strong>Import complete.</strong>
          <pre>{JSON.stringify(previewResult, null, 2)}</pre>
        </div>
      ) : null}
      {previewState !== 'done' && previewResult ? (
        <details>
          <summary>Preview output</summary>
          <pre>{JSON.stringify(previewResult, null, 2)}</pre>
        </details>
      ) : null}
    </section>
  );
}
