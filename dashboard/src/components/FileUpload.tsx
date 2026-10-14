'use client';

import { useState, useRef } from 'react';
import { apiPostForm } from '@/lib/api';
import ImportPreview from './ImportPreview';

interface PreviewData {
  success: boolean;
  channel: string;
  file: string;
  saved_path: string;
  summary: {
    total_rows: number;
    matched: number;
    unmatched: number;
    duplicates: number;
    errors: number;
    total_revenue: number;
  };
  unmatched_skus: Array<{ external_code: string; row_count: number; total_revenue: number }>;
  unmatched_customers: Array<{ external_name: string; row_count: number; total_revenue: number }>;
  sku_list: Array<{ sku_id: number; sku_code: string; description: string; canonical_name: string | null }>;
  customer_list: Array<{ customer_id: number; customer_name: string }>;
  rows: Array<Record<string, unknown>>;
  error?: string;
}

const font = { fontFamily: 'Inter, system-ui, sans-serif' };
const headingFont = { fontFamily: 'Cardo, serif' };

export default function FileUpload() {
  const [channel, setChannel] = useState<string>('dws');
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [previewData, setPreviewData] = useState<PreviewData | null>(null);
  const [dragActive, setDragActive] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const channelInfo: Record<string, { label: string; accept: string; hint: string }> = {
    dws: {
      label: 'DWS Report',
      accept: '.xlsx,.xls',
      hint: 'Excel (.xlsx) — monthly sell-through report from DWS',
    },
    alm: {
      label: 'ALM Report',
      accept: '.zip',
      hint: 'ZIP file — weekly ALM withdrawal reports (nested zips)',
    },
  };

  const handleUpload = async (file: File) => {
    setUploading(true);
    setError(null);
    setPreviewData(null);

    const formData = new FormData();
    formData.append('channel', channel);
    formData.append('file', file);

    try {
      const res = await apiPostForm('/api/upload/preview', formData);
      const data: PreviewData = await res.json();

      if (!data.success) {
        setError(data.error || 'Preview failed');
        return;
      }

      setPreviewData(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Upload failed');
    } finally {
      setUploading(false);
    }
  };

  const onFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) handleUpload(file);
  };

  const onDrop = (e: React.DragEvent) => {
    e.preventDefault();
    setDragActive(false);
    const file = e.dataTransfer.files?.[0];
    if (file) handleUpload(file);
  };

  const onDragOver = (e: React.DragEvent) => {
    e.preventDefault();
    setDragActive(true);
  };

  const onDragLeave = () => setDragActive(false);

  const handleReset = () => {
    setPreviewData(null);
    setError(null);
    if (fileInputRef.current) fileInputRef.current.value = '';
  };

  // Show ImportPreview if we have preview data
  if (previewData) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return <ImportPreview data={previewData as any} onReset={handleReset} />;
  }

  return (
    <div>
      <h3 className="text-sm font-semibold text-[#1F1F1F] uppercase tracking-wider mb-4" style={font}>
        Data Import Wizard
      </h3>

      <div className="rounded-xl border border-[#EBEBEC] bg-white p-5">
        {/* Channel Selector */}
        <div className="flex gap-2 mb-3">
          {Object.entries(channelInfo).map(([key, info]) => (
            <button
              key={key}
              onClick={() => { setChannel(key); setError(null); }}
              className={`px-4 py-2 rounded-lg text-xs font-medium transition-colors ${
                channel === key
                  ? 'bg-[#931220] text-white'
                  : 'bg-[#FAF9F7] border border-[#D8D9DA] text-[#505052] hover:bg-white hover:text-[#1F1F1F]'
              }`}
              style={font}
            >
              {info.label}
            </button>
          ))}
        </div>

        <p className="text-[11px] text-[#505052] mb-4" style={font}>
          {channelInfo[channel].hint}
        </p>

        {/* Drop Zone */}
        <div
          onDrop={onDrop}
          onDragOver={onDragOver}
          onDragLeave={onDragLeave}
          onClick={() => fileInputRef.current?.click()}
          className={`border-2 border-dashed rounded-xl p-8 text-center cursor-pointer transition-colors select-none ${
            dragActive
              ? 'border-[#931220] bg-[#931220]/5'
              : 'border-[#D8D9DA] hover:border-[#505052] hover:bg-[#FAF9F7]'
          } ${uploading ? 'pointer-events-none opacity-50' : ''}`}
        >
          <input
            ref={fileInputRef}
            type="file"
            accept={channelInfo[channel].accept}
            onChange={onFileChange}
            className="hidden"
          />

          {uploading ? (
            <div className="flex flex-col items-center gap-2">
              <div className="w-5 h-5 border-2 border-[#931220] border-t-transparent rounded-full animate-spin" />
              <p className="text-xs text-[#505052]" style={font}>Parsing file...</p>
              <p className="text-[10px] text-[#505052]/60" style={font}>Matching SKUs and customers against database</p>
            </div>
          ) : (
            <div>
              <p className="text-sm text-[#1F1F1F]" style={font}>
                Drop file here or click to browse
              </p>
              <p className="text-[10px] text-[#505052] mt-1" style={font}>
                {channelInfo[channel].accept} files accepted
              </p>
            </div>
          )}
        </div>

        {/* Error */}
        {error && (
          <div className="mt-4 rounded-lg p-4 text-xs bg-red-50 border border-red-200">
            <div className="flex items-start gap-2">
              <span className="text-[#931220] font-medium" style={font}>Error</span>
              <pre className="text-[#505052] whitespace-pre-wrap break-words font-mono text-[10px] flex-1">
                {error}
              </pre>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
